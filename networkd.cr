require "socket"

port = 210
server = TCPServer.new("127.0.0.1", port)
puts "NetworkD daemon active on port \033[34m#{port}\033[0m [\033[32mOK\033[0m]"

while client = server.accept?
  spawn do
    begin
      request = client.gets
      if request
        args = request.strip.split(/\s+/)
        cmd = args[0]? ? args[0].downcase : ""

        case cmd
        when "help"
          client.puts "\033[1mNetworkD Command Reference:\033[0m"
          client.puts "  up <interface>             - Bring up a network interface (e.g., eth0)"
          client.puts "  down <interface>           - Bring down a network interface"
          client.puts "  dhcp <interface>           - Run udhcpc on an interface for IP/DNS configuration"
          client.puts "  ip <args...>               - Run raw busybox ip command (e.g., ip addr show)"
        when "up"
          if iface = args[1]?
            status = Process.run("ip", ["link", "set", iface, "up"])
            client.puts status.exit_code == 0 ? "Interface #{iface} up >> \033[32m[OK]\033[0m" : "Interface #{iface} up >> \033[31m[FAIL]\033[0m"
          else
            client.puts "Usage: net up <interface>"
          end
        when "down"
          if iface = args[1]?
            status = Process.run("ip", ["link", "set", iface, "down"])
            client.puts status.exit_code == 0 ? "Interface #{iface} down >> \033[32m[OK]\033[0m" : "Interface #{iface} down >> \033[31m[FAIL]\033[0m"
          else
            client.puts "Usage: net down <interface>"
          end
        when "dhcp"
          if iface = args[1]?
            client.puts "Running udhcpc on #{iface}..."
            spawn do
              Process.run("udhcpc", ["-i", iface, "-n"])
            end
            client.puts "DHCP request sent for #{iface} >> \033[32m[OK]\033[0m"
          else
            client.puts "Usage: net dhcp <interface>"
          end
        when "ip"
          ip_args = args[1..-1]
          output = IO::Memory.new
          status = Process.run("ip", args: ip_args, output: output, error: output)
          client.puts output.to_s
        else
          client.puts "Unknown network command >> \033[31m[FAIL]\033[0m (Try 'net help')"
        end
      end
    rescue ex
      # Safely catch stream errors so the daemon never crashes
    ensure
      client.close rescue nil
    end
  end
end
