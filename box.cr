require "option_parser"
require "socket"

OptionParser.parse do |parser|
  parser.banner = "Usage: box [options] <command> [<args>]"
  parser.on("-h", "--help", "Show this help") do
    puts parser
    puts "\nCommands:"
    puts "  start <service>                   - Start a service (and dependencies)"
    puts "  stop <service>                    - Stop a service (and dependents)"
    puts "  restart <service>                 - Restart a service"
    puts "  reload                            - Reload service configurations"
    puts "  enable [--now] <service>          - Enable a service"
    puts "  disable [--now] <service>         - Disable a service"
    puts "  journal <service>                 - View full journal for a service"
    puts "  journal -t <lines> <service|all>  - Tail journal lines"
    puts "  journal -h <lines> <service|all>  - Head journal lines"
    puts "  journal -c [<lines>] <service|all>- Clear or truncate journal"
    puts "  list                              - List all loaded services"
    puts "  net <command> [<args>]            - Interact with networkd (up, down, dhcp, ip, help)"
    exit
  end
end

if ARGV.empty?
  STDERR.puts "Error: No command specified. Run 'box --help' for usage."
  exit 1
end

# Intercept 'net' commands and forward them to NetworkD on port 210
if ARGV[0].downcase == "net"
  net_args = ARGV[1..-1]
  request_string = net_args.empty? ? "help" : net_args.join(" ")

  begin
    client = TCPSocket.new("127.0.0.1", 210)
    client.puts(request_string)
    client.flush

    while line = client.gets
      print line + "\n"
    end

    client.close
  rescue ex
    STDERR.puts "[Box Error] Failed to communicate with NetworkD: #{ex.message}. Is networkd running?"
    exit 1
  end
  exit 0
end

request_string = ARGV.join(" ")

def send_request(request)
  # Try UNIX socket first (/services/boxd.sock or ./boxd.sock)
  socket_paths = ["/services/boxd.sock", "./boxd.sock"]
  socket_paths.each do |path|
    if File.exists?(path)
      begin
        socket = UNIXSocket.new(path)
        socket.puts(request)
        socket.flush
        while line = socket.gets
          print line + "\n"
        end
        socket.close
        return
      rescue
        # Fallback if connection fails
      end
    end
  end

  # Fallback to TCP daemon (Port 209)
  client = TCPSocket.new("127.0.0.1", 209)
  client.puts(request)
  client.flush

  while line = client.gets
    print line + "\n"
  end

  client.close
rescue ex
  STDERR.puts "[Box Error] Failed to communicate with BoxD: #{ex.message}. Is boxd running?"
  exit 1
end

send_request(request_string)
