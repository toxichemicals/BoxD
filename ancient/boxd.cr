require "option_parser"
require "file_utils"
require "json"

lib LibC
  AF_INET = 2
  SOCK_STREAM = 1
  SOL_SOCKET = 1
  SO_REUSEADDR = 2

  struct SockAddrIn
    sin_family : Int16
    sin_port : UInt16
    sin_addr : UInt32
    sin_zero : StaticArray(UInt8, 8)
  end

  fun mount(source : UInt8*, target : UInt8*, filesystemtype : UInt8*, mountflags : LibC::ULong, data : Void*) : Int
  fun waitpid(pid : Int32, status : Int*, options : Int) : Int
  fun socket(domain : Int32, type : Int32, protocol : Int32) : Int32
  fun bind(sockfd : Int32, addr : SockAddrIn*, addrlen : UInt32) : Int32
  fun listen(sockfd : Int32, backlog : Int32) : Int32
  fun accept(sockfd : Int32, addr : SockAddrIn*, addrlen : UInt32*) : Int32
  fun read(fd : Int32, buf : Void*, count : LibC::SizeT) : LibC::SSizeT
  fun write(fd : Int32, buf : Void*, count : LibC::SizeT) : LibC::SSizeT
  fun close(fd : Int32) : Int32
  fun setsockopt(sockfd : Int32, level : Int32, optname : Int32, optval : Void*, optlen : UInt32) : Int32
  fun inet_addr(cp : UInt8*) : UInt32

  # Raw C Process & TTY Control FFI
  fun fork : Int32
  fun setsid : Int32
  fun open(path : UInt8*, flags : Int32, mode : Int32) : Int32
  fun dup2(oldfd : Int32, newfd : Int32) : Int32
  fun ioctl(fd : Int32, request : UInt64, ...) : Int32
  fun execve(pathname : UInt8*, argv : UInt8**, envp : UInt8**) : Int32
  fun _exit(status : Int32) : NoReturn
end

module MountD
  def self.initialize_mounts
    if Process.pid == 1
      puts "[MountD] PID 1 detected. Initializing core virtual filesystems..."
      
      dirs = ["/proc", "/sys", "/dev", "/dev/pts"]
      dirs.each { |d| Dir.mkdir_p(d) rescue nil }

      flags = LibC::ULong.new(0)
      LibC.mount("proc".to_unsafe, "/proc".to_unsafe, "proc".to_unsafe, flags, nil)
      LibC.mount("sysfs".to_unsafe, "/sys".to_unsafe, "sysfs".to_unsafe, flags, nil)
      LibC.mount("devtmpfs".to_unsafe, "/dev".to_unsafe, "devtmpfs".to_unsafe, flags, nil)
      LibC.mount("devpts".to_unsafe, "/dev/pts".to_unsafe, "devpts".to_unsafe, flags, nil)

      puts "[MountD] Bringing up loopback interface (lo)..."
      Process.run("ip", ["link", "set", "lo", "up"]) rescue nil
      Process.run("ip", ["addr", "add", "127.0.0.1/8", "dev", "lo"]) rescue nil
      Process.run("ifconfig", ["lo", "up", "127.0.0.1"]) rescue nil

      if File.exists?("/etc/fstab")
        puts "[MountD] Found /etc/fstab, executing mount -a..."
        Process.run("mount", ["-a"]) rescue nil
      end
      puts "[MountD] Core mounts completed successfully."
    end
  end
end

module ReapD
  def self.start_reaper
    if Process.pid == 1
      puts "[ReapD] Initializing zombie process reaper..."
      spawn do
        loop do
          status = 0
          pid = LibC.waitpid(-1, pointerof(status), 0)
          if pid <= 0
            sleep 100.milliseconds
          end
        end
      end
    end
  end
end

class ServiceConfig
  property name : String
  property file_path : String
  property runner : String?
  property shell : String?
  property path_env : String?
  property exec_cmd : String?
  property inscript : String?
  property shutdown_cmd : String?
  property autorestart : Bool = false
  property waiton : String?
  property enabled : Bool = true

  def initialize(@name : String, @file_path : String)
    reload
  end

  def reload
    content = File.read(@file_path)
    lines = content.lines
    in_inscript = false
    inscript_buffer = [] of String

    lines.each do |line|
      stripped = line.strip
      if in_inscript
        if stripped == "}"
          in_inscript = false
          @inscript = inscript_buffer.join("\n")
        else
          inscript_buffer << line
        end
        next
      end

      if stripped.starts_with?("Inscript{")
        in_inscript = true
        next
      end

      next if stripped.empty? || stripped.starts_with?("#")
      parts = stripped.split('=', 2)
      next if parts.size != 2
      key = parts[0].strip.downcase
      val = parts[1].strip

      case key
      when "runner" then @runner = val
      when "shell" then @shell = val
      when "path" then @path_env = val
      when "exec" then @exec_cmd = val
      when "shutdown" then @shutdown_cmd = val
      when "autorestart" then @autorestart = (val.downcase == "y" || val.downcase == "true")
      when "waiton" then @waiton = val
      when "enabled" then @enabled = (val.downcase == "y" || val.downcase == "true")
      end
    end
  end
end

class ServiceRunner
  property config : ServiceConfig
  property process : Process?
  property running : Bool = false
  property journals_dir : String

  def initialize(@config : ServiceConfig, @journals_dir : String)
  end

  def start(io : IO? = nil)
    unless @config.enabled
      io.try &.puts("\033[33m[WARN]\033[0m Service #{@config.name} is disabled.")
      return false
    end
    return true if @running

    @running = true
    cmd = @config.exec_cmd
    ins = @config.inscript

    unless cmd || ins
      @running = false
      io.try &.puts("\033[31m[FAIL]\033[0m (Missing 'exec' or 'Inscript')")
      return false
    end

    is_tty_service = @config.name.starts_with?("tty") || (cmd && (cmd.includes?("getty") || cmd.includes?("agetty")))

    if is_tty_service
      # Raw C fork + setsid + controlling terminal acquisition for TTY/getty services
      c_pid = LibC.fork
      if c_pid == 0
        LibC.setsid
        tty_path = (@config.name.starts_with?("tty") ? "/dev/#{@config.name}" : "/dev/tty1")
        tty_fd = LibC.open(tty_path.to_unsafe, 2, 0) # O_RDWR = 2
        if tty_fd >= 0
          LibC.dup2(tty_fd, 0)
          LibC.dup2(tty_fd, 1)
          LibC.dup2(tty_fd, 2)
          LibC.ioctl(0, 0x540E_u64, 0) # TIOCSCTTY
          if tty_fd > 2
            LibC.close(tty_fd)
          end
        end

        shell_bin = @config.shell ? (@config.shell.not_nil!.downcase.in?("true", "y") ? "/bin/sh" : @config.shell.not_nil!) : "/bin/sh"
        exec_str = cmd.not_nil!
        args = @config.shell ? [shell_bin, "-c", exec_str] : exec_str.split(" ")
        exec_target = args[0]

        c_argv = args.map(&.to_unsafe)
        c_argv << Pointer(UInt8).null

        env = ENV.to_h
        if p = @config.path_env
          env["PATH"] = "#{p}:#{ENV["PATH"]? || "/bin:/usr/bin"}"
        end
        env_strings = env.map { |k, v| "#{k}=#{v}" }
        c_envp = env_strings.map(&.to_unsafe)
        c_envp << Pointer(UInt8).null

        LibC.execve(exec_target.to_unsafe, c_argv.to_unsafe, c_envp.to_unsafe)
        LibC._exit(127)
      elsif c_pid > 0
        @running = true
        io.try &.puts("\033[32m[OK]\033[0m")
        return true
      else
        @running = false
        io.try &.puts("\033[31m[FAIL]\033[0m (Fork failed)")
        return false
      end
    else
      # Standard background daemon spawning
      spawn do
        log_path = File.join(@journals_dir, "#{@config.name}.log")
        begin
          loop do
            shell_bin = @config.shell ? (@config.shell.not_nil!.downcase.in?("true", "y") ? "/bin/sh" : @config.shell.not_nil!) : "/bin/sh"
            env = ENV.to_h
            if p = @config.path_env
              env["PATH"] = "#{p}:#{ENV["PATH"]? || "/bin:/usr/bin"}"
            end

            begin
              log_file = File.open(log_path, "a")
              log_file.puts("\n--- [BoxD] Starting #{@config.name} at #{Time.local} ---")

              if script_body = @config.inscript
                proc = Process.new(shell_bin, env: env, output: log_file, error: log_file, input: Process::Redirect::Pipe)
                proc.input.print(script_body)
                proc.input.close
                @process = proc
                proc.wait
              else
                exec_str = cmd.not_nil!
                args = @config.shell ? ["-c", exec_str] : exec_str.split(" ")
                exec_target = @config.shell ? shell_bin : args.shift
                proc = Process.new(exec_target, args: args, env: env, output: log_file, error: log_file)
                @process = proc
                proc.wait
              end
              log_file.close
            rescue ex
              puts "[BoxD Error] Failed to run #{@config.name}: #{ex.message}"
            end

            break unless @config.autorestart && @running
            sleep 2.seconds
          end
        ensure
          @process = nil
          @running = false
        end
      end
      io.try &.puts("\033[32m[OK]\033[0m")
      true
    end
  end

  def stop(io : IO? = nil)
    unless @running
      io.try &.puts("\033[31m[FAIL]\033[0m (Not running)")
      return false
    end

    if sc = @config.shutdown_cmd
      io.try &.print("Running shutdown script for #{@config.name} >> ")
      shell_bin = @config.shell ? (@config.shell.not_nil!.downcase.in?("true", "y") ? "/bin/sh" : @config.shell.not_nil!) : "/bin/sh"
      env = ENV.to_h
      if p = @config.path_env
        env["PATH"] = "#{p}:#{ENV["PATH"]? || "/bin:/usr/bin"}"
      end
      begin
        log_path = File.join(@journals_dir, "#{@config.name}.log")
        log_file = File.open(log_path, "a")
        Process.run(shell_bin, args: ["-c", sc], env: env, output: log_file, error: log_file)
        log_file.close
        io.try &.puts("\033[32m[OK]\033[0m")
      rescue ex
        io.try &.puts("\033[31m[FAIL]\033[0m (#{ex.message})")
      end
    end

    @running = false
    if proc = @process
      proc.terminate rescue nil
      proc.wait rescue nil
      @process = nil
    end

    io.try &.puts("\033[32m[OK]\033[0m")
    true
  end
end

def start_with_dependencies(name : String, services : Hash(String, ServiceRunner), client_io : IO? = nil, visiting = [] of String)
  runner = services[name]?
  unless runner
    client_io.try &.puts("#{name} >> \033[31m[FAIL]\033[0m (Dependency not found)")
    return false
  end
  return false if visiting.includes?(name)
  return true if runner.running

  if parent_name = runner.config.waiton
    client_io.try &.puts("\033[33m[INFO]\033[0m #{name} waiting on dependency #{parent_name}...")
    success = start_with_dependencies(parent_name, services, client_io, visiting + [name])
    return false unless success
  end

  client_io.try &.print("#{name} >> ")
  runner.start(client_io)
end

def stop_with_dependencies(name : String, services : Hash(String, ServiceRunner), client_io : IO? = nil, stopped = [] of String)
  return if stopped.includes?(name)
  runner = services[name]?
  return unless runner

  services.each do |other_name, other_runner|
    if other_runner.config.waiton == name && other_runner.running
      stop_with_dependencies(other_name, services, client_io, stopped)
    end
  end

  if runner.running
    client_io.try &.print("#{name} >> ")
    runner.stop(client_io)
    stopped << name
  end
end

def perform_system_shutdown(services : Hash(String, ServiceRunner))
  puts "\n[BoxD] Shutting down services..."
  services.keys.each { |name| stop_with_dependencies(name, services, STDOUT) }
  puts "[BoxD] Shutdown complete."
end

userland = false
dir = (Process.pid == 1) ? "/services/" : Dir.current

OptionParser.parse do |parser|
  parser.banner = "Usage: boxd [options]"
  parser.on("-u", "--user", "Run in userland mode") { userland = true }
  parser.on("-d DIR", "--dir DIR", "Directory containing .serv files") { |d| dir = d }
  parser.on("-h", "--help", "Show this help") { puts parser; exit }
end

MountD.initialize_mounts
ReapD.start_reaper

Dir.mkdir_p(dir) unless Dir.exists?(dir)
journals_dir = File.join(dir, "journals")
Dir.mkdir_p(journals_dir)

serv_files = Dir.glob(File.join(dir, "*.serv"))
puts "Discovering services >> [\033[34m#{serv_files.size}\033[0m] \033[32m[OK]\033[0m"

db_path = File.join(dir, "services.db")
services = {} of String => ServiceRunner
services_meta = [] of Hash(String, String)

serv_files.each do |file|
  name = File.basename(file, ".serv")
  config = ServiceConfig.new(name, file)
  services[name] = ServiceRunner.new(config, journals_dir)
  services_meta << { "name" => name, "path" => file }
end
File.write(db_path, services_meta.to_json)

Signal::INT.trap do
  perform_system_shutdown(services)
  exit 0
end

Signal::TERM.trap do
  perform_system_shutdown(services)
  exit 0
end

puts "Auto-starting enabled services >>"
services.each do |name, runner|
  if runner.config.enabled && !runner.running
    start_with_dependencies(name, services, STDOUT)
  end
end

# --- RAW C SOCKET SERVER IMPLEMENTATION ---
server_fd = LibC.socket(LibC::AF_INET, LibC::SOCK_STREAM, 0)
if server_fd < 0
  STDERR.puts "[BoxD Error] Failed to create raw socket."
  exit 1
end

opt = 1
LibC.setsockopt(server_fd, LibC::SOL_SOCKET, LibC::SO_REUSEADDR, pointerof(opt).as(Void*), sizeof(Int32).to_u32)

addr = LibC::SockAddrIn.new
addr.sin_family = LibC::AF_INET.to_i16
addr.sin_port = 54016_u16 # Port 211 in network byte order
addr.sin_addr = LibC.inet_addr("127.0.0.1".to_unsafe)

if LibC.bind(server_fd, pointerof(addr), sizeof(LibC::SockAddrIn).to_u32) < 0
  STDERR.puts "[BoxD Error] Failed to bind raw socket to 127.0.0.1:211"
  exit 1
end

if LibC.listen(server_fd, 128) < 0
  STDERR.puts "[BoxD Error] Failed to listen on raw socket."
  exit 1
end

puts "BoxD raw C daemon active on port \033[34m211\033[0m [\033[32mOK\033[0m]"

loop do
  client_fd = LibC.accept(server_fd, nil, nil)
  next if client_fd < 0

  spawn do
    begin
      buf = Slice(UInt8).new(1024, 0)
      bytes_read = LibC.read(client_fd, buf.to_unsafe, buf.size.to_u64)
      if bytes_read > 0
        request = String.new(buf[0, bytes_read]).strip
        response_io = IO::Memory.new
        args = request.split(/\s+/)
        cmd = args[0]? ? args[0].downcase : ""

        case cmd
        when "list"
          response_io.puts "\033[1mLoaded Services:\033[0m"
          services.each do |name, runner|
            status = runner.running ? "\033[32mRUNNING\033[0m" : "\033[31mSTOPPED\033[0m"
            enabled = runner.config.enabled ? "\033[32m[enabled]\033[0m" : "\033[33m[disabled]\033[0m"
            response_io.puts " - #{name} [#{status}] #{enabled}"
          end
        when "start"
          target = args[1]? || ""
          if services.has_key?(target)
            start_with_dependencies(target, services, response_io)
          else
            response_io.puts "#{target} >> \033[31m[FAIL]\033[0m (Service not found)"
          end
        when "stop"
          target = args[1]? || ""
          if services.has_key?(target)
            stop_with_dependencies(target, services, response_io)
          else
            response_io.puts "#{target} >> \033[31m[FAIL]\033[0m (Service not found)"
          end
        when "restart"
          target = args[1]? || ""
          if services.has_key?(target)
            response_io.puts "Restarting #{target}..."
            stop_with_dependencies(target, services, response_io)
            sleep 1.second
            start_with_dependencies(target, services, response_io)
          else
            response_io.puts "Restart #{target} >> \033[31m[FAIL]\033[0m (Service not found)"
          end
        when "reload"
          serv_files = Dir.glob(File.join(dir, "*.serv"))
          serv_files.each do |file|
            name = File.basename(file, ".serv")
            if runner = services[name]?
              runner.config.file_path = file
              runner.config.reload
            else
              config = ServiceConfig.new(name, file)
              services[name] = ServiceRunner.new(config, journals_dir)
            end
          end
          response_io.puts "Reload services >> \033[32m[OK]\033[0m"
        else
          response_io.puts "Unknown command >> \033[31m[FAIL]\033[0m (#{request})"
        end

        response_io.flush
        resp_str = response_io.to_s
        LibC.write(client_fd, resp_str.to_unsafe, resp_str.bytesize.to_u64)
      end
    rescue ex
      err = "Server error >> \033[31m[FAIL]\033[0m (#{ex.message})\n"
      LibC.write(client_fd, err.to_unsafe, err.bytesize.to_u64)
    ensure
      LibC.close(client_fd)
    end
  end
end
