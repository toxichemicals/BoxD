require "option_parser"
require "file_utils"

class BuildConfig
  property exec_val : String = "inline"
  property final_val : String = "dist"
  property script_content : String = ""

  def self.parse(filename : String)
    config = new
    unless File.exists?(filename)
      raise "Error: Build file '#{filename}' not found in package directory."
    end

    lines = File.read_lines(filename)
    in_inscript = false
    script_lines = [] of String

    lines.each do |line|
      stripped = line.strip
      if stripped.starts_with?("exec=")
        config.exec_val = stripped[5..-1].strip
      elsif stripped.starts_with?("final=")
        config.final_val = stripped[6..-1].strip
      elsif stripped.starts_with?("inscript") && stripped.includes?("{")
        in_inscript = true
        parts = stripped.split("{", 2)
        if parts.size > 1 && !parts[1].strip.empty?
          script_lines << parts[1].strip.chomp("}")
        end
        next
      end

      if in_inscript
        if stripped == "}"
          in_inscript = false
        else
          script_lines << line
        end
      end
    end

    config.script_content = script_lines.join("\n")
    config
  end
end

def find_final_dir(base_dir : String, final_val : String) : String
  direct_path = File.join(base_dir, final_val)
  return direct_path if Dir.exists?(direct_path)

  Dir.each_child(base_dir) do |child|
    child_path = File.join(base_dir, child)
    if File.directory?(child_path)
      nested_path = File.join(child_path, final_val)
      return nested_path if Dir.exists?(nested_path)
    end
  end

  direct_path
end

def bundle_dependencies(final_dir : String)
  unless Dir.exists?(final_dir)
    puts "  -> Warning: Final directory '#{final_dir}' does not exist yet. Skipping dependency bundling."
    return
  end
  lib_target_dir = File.join(final_dir, "usr", "lib")
  FileUtils.rm_rf(lib_target_dir)
  FileUtils.mkdir_p(lib_target_dir)
  
  Dir.glob("#{final_dir}/**/*") do |path|
    next if File.directory?(path)
    next if path.includes?("/usr/lib/")
    
    is_elf = false
    File.open(path, "r") do |file|
      buffer = Bytes.new(4)
      bytes_read = file.read(buffer)
      if bytes_read == 4 && buffer[0] == 0x7f && buffer[1] == 'E'.ord && buffer[2] == 'L'.ord && buffer[3] == 'F'.ord
        is_elf = true
      end
    end
    next unless is_elf

    status = Process.run("ldd", [path], output: out_io = IO::Memory.new, error: Process::Redirect::Close)
    if status.success?
      out_io.to_s.each_line do |line|
        if line =~ /\=\>\s*(\/[^\s]+)/
          lib_path = $1
          lib_name = File.basename(lib_path)
          next if lib_name =~ /^(libc|libm|libdl|libpthread|librt|ld-linux)/
          if File.exists?(lib_path)
            dest_path = File.join(lib_target_dir, lib_name)
            unless File.exists?(dest_path)
              FileUtils.cp(lib_path, dest_path)
              puts "  -> Bundled dependency: #{lib_path} -> #{dest_path}"
            end
          end
        end
      end
    end
  end
end

def main
  deploy_host = nil
  ssh_port = nil

  OptionParser.parse do |parser|
    parser.banner = "Usage: tapepack --deploy user@host [-p port]"
    parser.on("-d HOST", "--deploy=HOST", "Remote SSH build host") { |h| deploy_host = h }
    parser.on("-p PORT", "--port=PORT", "SSH port number") { |p| ssh_port = p }
    parser.on("--help", "Show help") do
      puts parser
      exit
    end
  end

  current_dir = Dir.current
  pkg_name = File.basename(current_dir)
  build_me_path = "build.me"

  puts "==> Parsing build.me configuration..."
  build_config = BuildConfig.parse(build_me_path)

  exec_command = if build_config.exec_val == "inline"
    script_file = ".tape_exec_script.sh"
    File.write(script_file, build_config.script_content)
    "if command -v bash &> /dev/null; then bash #{script_file}; else sh #{script_file}; fi"
  else
    build_config.exec_val
  end

  port_ssh = ssh_port ? "-p #{ssh_port}" : ""
  port_rsync = ssh_port ? %Q( -e "ssh -p #{ssh_port}" ) : ""

  if deploy_host
    puts "==> [1/5] Preparing remote deployment path on #{deploy_host}..."
    remote_path = "~/temp/tapepkg/deploy/#{pkg_name}"
    run_cmd("ssh #{port_ssh} #{deploy_host} 'mkdir -p #{remote_path}'")

    puts "==> [2/5] Syncing package directory via rsync..."
    run_cmd("rsync -avz#{port_rsync} --exclude '*.cr' ./ #{deploy_host}:#{remote_path}/")

    puts "==> [3/5] Executing remote build..."
    remote_build_cmd = "cd #{remote_path} && #{exec_command}"
    run_cmd("ssh #{port_ssh} #{deploy_host} \"#{remote_build_cmd}\"")

    puts "==> [4/5] Auto-bundling shared library dependencies remotely..."
    bundle_script = ".tape_bundle_script.sh"
    File.write(bundle_script, <<-BASH)
FINAL_DIR=\$(find . -type d -name '#{build_config.final_val}' | head -n 1)
if [ -z "\$FINAL_DIR" ]; then
  echo 'ERROR: Could not find final directory "#{build_config.final_val}".'
  exit 1
fi
rm -rf "\$FINAL_DIR/usr/lib"
mkdir -p "\$FINAL_DIR/usr/lib"

find "\$FINAL_DIR" -type f \\( -path "*/bin/*" -o -path "*/sbin/*" -o -not -path "*/usr/lib/*" \\) | while read -r f; do
  if file "\$f" | grep -qE "ELF.*(executable|shared object)"; then
    echo "Inspecting binary with file: \$f"
    ldd "\$f" 2>/dev/null | grep '=>' | while read -r line; do
      lib_name=\$(echo "\$line" | awk '{print \$1}')
      lib_path=\$(echo "\$line" | awk '{print \$3}')
      
      case "\$lib_name" in
        libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|ld-linux*|linux-vdso*)
          continue
          ;;
      esac
      
      if [ -f "\$lib_path" ]; then
        echo "  -> Bundling dependency: \$lib_path"
        cp -f "\$lib_path" "\$FINAL_DIR/usr/lib/"
      fi
    done
  fi
done
echo "Final bundled libraries:"
ls -la "\$FINAL_DIR/usr/lib" || true
BASH
    run_cmd("rsync -avz#{port_rsync} #{bundle_script} #{deploy_host}:#{remote_path}/")
    run_cmd("ssh #{port_ssh} #{deploy_host} 'cd #{remote_path} && bash #{bundle_script}'")
    File.delete(bundle_script) if File.exists?(bundle_script)

    puts "==> [5/5] Archiving package..."
    pack_script = ".tape_pack_script.sh"
    File.write(pack_script, <<-BASH)
FINAL_DIR=\$(find . -type d -name '#{build_config.final_val}' | head -n 1)
if [ -z "\$FINAL_DIR" ]; then
  echo 'Error: Final dir not found'
  exit 1
fi
rm -f #{pkg_name}.tar.zst
tar --zstd -C "\$FINAL_DIR" -cf #{pkg_name}.tar.zst .
BASH
    run_cmd("rsync -avz#{port_rsync} #{pack_script} #{deploy_host}:#{remote_path}/")
    run_cmd("ssh #{port_ssh} #{deploy_host} 'cd #{remote_path} && bash #{pack_script}'")
    File.delete(pack_script) if File.exists?(pack_script)
    
    run_cmd("rsync -avz#{port_rsync} #{deploy_host}:~/temp/tapepkg/deploy/#{pkg_name}/#{pkg_name}.tar.zst ./")
    puts "==> Success! Artifact downloaded: #{pkg_name}.tar.zst"
  else
    puts "==> [1/3] Building locally..."
    run_cmd(exec_command)

    resolved_final = find_final_dir(current_dir, build_config.final_val)

    puts "==> [2/3] Auto-bundling shared library dependencies into #{resolved_final}..."
    bundle_dependencies(resolved_final)

    puts "==> [3/3] Archiving final directory (#{resolved_final}) to #{pkg_name}.tar.zst..."
    unless Dir.exists?(resolved_final)
      STDERR.puts "Error: Final directory '#{resolved_final}' not found after build."
      exit 1
    end
    pack_cmd = "tar --zstd -C '#{resolved_final}' -cf '#{pkg_name}.tar.zst' ."
    run_cmd(pack_cmd)
    puts "==> Success! Local archive created: #{pkg_name}.tar.zst"
  end

  File.delete(".tape_exec_script.sh") if File.exists?(".tape_exec_script.sh")
end

def run_cmd(cmd : String)
  puts "  -> Running: #{cmd}"
  status = Process.run(
    cmd,
    shell: true,
    output: Process::Redirect::Inherit,
    error: Process::Redirect::Inherit
  )
  unless status.success?
    STDERR.puts "Error: Command failed with exit status #{status.exit_code}"
    exit 1
  end
end

main
