require "option_parser"

def main
  local_pkg = nil.as(String?)
  target_dir = "/"
  remove_pkg = nil.as(String?)
  sync_mode = false
  clean_mode = false

  OptionParser.parse do |parser|
    parser.banner = "Usage: tape [options]"
    parser.on("-l PATH", "--local=PATH", "Install a local .tar.zst package") { |p| local_pkg = p }
    parser.on("-D DIR", "--dir=DIR", "Custom target root directory (default: /)") { |d| target_dir = d }
    parser.on("-r PKG", "--remove=PKG", "Remove an installed package") { |r| remove_pkg = r }
    parser.on("-S", "--sync", "Sync with remote package repositories from GitHub") { sync_mode = true }
    parser.on("-C", "--clean", "Clean downloaded synced caches") { clean_mode = true }
    parser.on("--help", "Show help options") do
      puts parser
      exit
    end
  end

  target_dir = File.expand_path(target_dir)

  if pkg = local_pkg
    install_local(pkg, target_dir)
  elsif pkg = remove_pkg
    remove_package(pkg, target_dir)
  elsif sync_mode
    puts "==> [Sync] Syncing repository lists from GitHub... (To be implemented)"
  elsif clean_mode
    puts "==> [Clean] Cleaning downloaded sync caches... (To be implemented)"
  else
    puts "Error: No action specified. Use --help for usage information."
    exit 1
  end
end

def install_local(archive_path : String, target_dir : String)
  unless File.exists?(archive_path)
    STDERR.puts "Error: Package archive '#{archive_path}' not found."
    exit 1
  end

  pkg_filename = File.basename(archive_path)
  pkg_name = pkg_filename.chomp(".tar.zst").sub(/\.tar$/, "")

  puts "==> Installing local package '#{pkg_name}' into target root: #{target_dir}..."

  file_list_output = IO::Memory.new
  status = Process.run("tar", ["--zstd", "-tf", archive_path], output: file_list_output)
  unless status.success?
    STDERR.puts "Error: Failed to read package contents."
    exit 1
  end

  files = file_list_output.to_s.split("\n").map(&.strip).reject(&.empty?)

  extract_status = Process.run("tar", ["--zstd", "-xf", archive_path, "-C", target_dir])
  unless extract_status.success?
    STDERR.puts "Error: Failed to extract package into #{target_dir}."
    exit 1
  end

  metadata_dir = File.join(target_dir, "var/lib/tape/installed")
  Dir.mkdir_p(metadata_dir)
  metadata_file = File.join(metadata_dir, "#{pkg_name}.files")
  File.write(metadata_file, files.join("\n"))

  puts "==> Successfully installed #{pkg_name}!"
end

def remove_package(pkg_name : String, target_dir : String)
  metadata_file = File.join(target_dir, "var/lib/tape/installed/#{pkg_name}.files")
  unless File.exists?(metadata_file)
    STDERR.puts "Error: Package '#{pkg_name}' is not recorded as installed in #{target_dir}."
    exit 1
  end

  puts "==> Removing package '#{pkg_name}' from target root: #{target_dir}..."

  files = File.read_lines(metadata_file).map(&.strip).reject(&.empty?)

  files.reverse_each do |rel_path|
    next if rel_path == "." || rel_path == "./"

    clean_rel = rel_path.sub(/^\.\//, "")
    full_path = File.join(target_dir, clean_rel)

    if File.file?(full_path) || File.symlink?(full_path)
      File.delete(full_path)
      print "  -> Removed file: #{clean_rel}\n"
    elsif Dir.exists?(full_path)
      if Dir.children(full_path).empty?
        Dir.delete(full_path) # Fixed from Dir.rmdir to Dir.delete
        print "  -> Removed directory: #{clean_rel}\n"
      end
    end
  end

  File.delete(metadata_file)
  puts "==> Successfully removed #{pkg_name}!"
end

main
