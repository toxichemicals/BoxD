require "socket"

port = 210
server = TCPServer.new("127.0.0.1", port)
puts "NetworkD daemon active on port \033[34m#{port}\033[0m [\033[32mOK\033[0m]"

# Native helper to inspect system interfaces directly from kernel sysfs[cite: 4]
def get_interfaces
  Dir.entries("/sys/class/net").reject { |f| f == "." || f == ".." }
end

while client = server.accept?
  spawn do
    begin
      request = client.gets
      if request
        args = request.strip.split(/\s+/)
        cmd = args[0]? ? args[0].downcase : ""

        case cmd
        when "help"
          client.puts "\033[1mBoxD NetworkD Manager Reference:\033[0m"
          client.puts "  interfaces                                - List all system network interfaces & state"
          client.puts "  up <interface> [ip/mask] [gateway] [dns]  - Bring up an interface (supports static IP)"
          client.puts "  down <interface>                          - Bring down an interface"
          client.puts "  dhcp <interface>                          - Request IP address via DHCP (udhcpc)"
          client.puts "  wifi-scan [interface]                     - Scan available Wi-Fi networks"
          client.puts "  wifi-connect <ssid> <pass> [iface]        - Connect to a Wi-Fi network"
          client.puts "  wifi-disconnect                           - Disconnect active Wi-Fi"

        when "interfaces"
          client.puts "\033[1mDetected Interfaces:\033[0m"
          get_interfaces.each do |iface|
            state_file = "/sys/class/net/#{iface}/operstate"
            state = File.exists?(state_file) ? File.read(state_file).strip : "unknown"
            status_color = state == "up" ? "\033[32m" : "\033[31m"
            type_flag = iface.starts_with?("wl") ? " [Wireless]" : (iface == "lo" ? " [Loopback]" : " [Ethernet]")
            client.puts "  - #{iface}#{type_flag} [#{status_color}#{state}\033[0m]"
          end

        when "up"
          if iface = args[1]?
            if get_interfaces.includes?(iface)
              # 1. Bring the link up
              status = Process.run("ip", ["link", "set", iface.not_nil!, "up"])
              if status.exit_code != 0
                client.puts "Interface #{iface} up >> \033[31m[FAIL]\033[0m"
                next
              end

              ip_addr = args[2]?
              gateway = args[3]?
              dns = args[4]?

              if ip_addr
                # Flush existing IPs to prevent "File exists" conflicts
                Process.run("ip", ["addr", "flush", "dev", iface.not_nil!])
                addr_status = Process.run("ip", ["addr", "add", ip_addr, "dev", iface.not_nil!])
                if addr_status.exit_code != 0
                  client.puts "Failed to set IP #{ip_addr} on #{iface} >> \033[31m[FAIL]\033[0m"
                  next
                end
              end

              if gateway
                # Clean up old default routes before adding the new one
                Process.run("ip", ["route", "del", "default"]) rescue nil
                route_status = Process.run("ip", ["route", "add", "default", "via", gateway, "dev", iface.not_nil!])
                if route_status.exit_code != 0
                  client.puts "Warning: Failed to set default gateway #{gateway} >> \033[31m[FAIL]\033[0m"
                end
              end

              if dns
                begin
                  File.write("/etc/resolv.conf", "nameserver #{dns}\n")
                rescue ex
                  client.puts "Warning: Failed to configure DNS: #{ex.message}"
                end
              end

              config_msg = ip_addr ? " (Static: #{ip_addr}, GW: #{gateway || "none"})" : ""
              client.puts "Interface #{iface} up#{config_msg} >> \033[32m[OK]\033[0m"
            else
              client.puts "Interface '#{iface}' not found >> \033[31m[FAIL]\033[0m"
            end
          else
            client.puts "Usage: net up <interface> [ip/mask] [gateway] [dns]"
          end

        when "down"
          if iface = args[1]?
            if get_interfaces.includes?(iface)
              status = Process.run("ip", ["link", "set", iface.not_nil!, "down"])
              client.puts status.exit_code == 0 ? "Interface #{iface} down >> \033[32m[OK]\033[0m" : "Interface #{iface} down >> \033[31m[FAIL]\033[0m"
            else
              client.puts "Interface '#{iface}' not found >> \033[31m[FAIL]\033[0m"
            end
          else
            client.puts "Usage: net down <interface>"
          end

        when "dhcp"
          if iface = args[1]?
            if get_interfaces.includes?(iface)
              client.puts "Broadcasting DHCP request on #{iface}..."
              
              # Ensure standard udhcpc event script exists
              script_path = "/etc/udhcpc.script"
              unless File.exists?(script_path)
                Dir.mkdir_p("/etc") rescue nil
                script_content = <<-SCRIPT
#!/bin/sh
case "$1" in
    deconfig)
        ip addr flush dev "$interface"
        ;;
    bound|renew)
        ip addr flush dev "$interface"
        ip addr add "$ip/$subnet" dev "$interface"
        if [ -n "$router" ]; then
            ip route del default via "$router" dev "$interface" 2>/dev/null || true
            ip route add default via "$router" dev "$interface"
        fi
        if [ -n "$dns" ]; then
            echo "nameserver $dns" > /etc/resolv.conf
        fi
        ;;
esac
SCRIPT
                File.write(script_path, script_content)
                Process.run("chmod", ["+x", script_path])
              end

              spawn do
                # 1. Bring the link up before querying DHCP
                Process.run("ip", ["link", "set", iface.not_nil!, "up"])
                # 2. Run udhcpc with our event script
                Process.run("udhcpc", ["-i", iface.not_nil!, "-s", script_path, "-n", "-q"])
              end
              client.puts "DHCP daemon dispatched for #{iface} >> \033[32m[OK]\033[0m"
            else
              client.puts "Interface '#{iface}' not found >> \033[31m[FAIL]\033[0m"
            end
          else
            client.puts "Usage: net dhcp <interface>"
          end

        when "wifi-scan"
          iface = args[1]? || get_interfaces.find { |i| i.starts_with?("wl") }
          if iface
            client.puts "Scanning wireless spectrum on #{iface}..."
            output = IO::Memory.new
            Process.run("ip", ["link", "set", iface.not_nil!, "up"])
            
            status = Process.run("iw", ["dev", iface.not_nil!, "scan"], output: output, error: output)
            if status.exit_code != 0
              output.clear
              Process.run("wpa_cli", ["-i", iface.not_nil!, "scan"], output: output, error: output)
              sleep 1
              output.clear
              Process.run("wpa_cli", ["-i", iface.not_nil!, "scan_results"], output: output, error: output)
            end
            
            res = output.to_s
            client.puts res.empty? ? "No networks found or wireless tool missing." : res
          else
            client.puts "No wireless interface detected on system."
          end

        when "wifi-connect"
          ssid = args[1]?
          password = args[2]?
          iface = args[3]? || get_interfaces.find { |i| i.starts_with?("wl") }

          if ssid && password && iface
            client.puts "Configuring secure link for '#{ssid}' on #{iface}..."
            
            Process.run("killall", ["wpa_supplicant"]) rescue nil

            conf_path = "/tmp/wpa_#{iface}.conf"
            conf_content = <<-CONF
            ctrl_interface=/var/run/wpa_supplicant
            update_config=1

            network={
                ssid="#{ssid}"
                psk="#{password}"
            }
            CONF
            File.write(conf_path, conf_content)

            spawn do
              Process.run("wpa_supplicant", ["-B", "-i", iface.not_nil!, "-c", conf_path])
              sleep 2
              Process.run("udhcpc", ["-i", iface.not_nil!, "-n", "-q"])
            end

            client.puts "Handshake and DHCP sequence triggered for #{ssid} >> \033[32m[OK]\033[0m"
          else
            client.puts "Usage: net wifi-connect <ssid> <password> [interface]"
          end

        when "wifi-disconnect"
          iface = args[1]? || get_interfaces.find { |i| i.starts_with?("wl") }
          if iface
            Process.run("killall", ["wpa_supplicant"]) rescue nil
            Process.run("ip", ["link", "set", iface.not_nil!, "down"])
            client.puts "Wi-Fi interface safely disabled >> \033[32m[OK]\033[0m"
          else
            client.puts "No wireless interface found."
          end

        else
          client.puts "Unknown network command >> \033[31m[FAIL]\033[0m (Try 'net help')"
        end
      end
    rescue ex
      client.puts "Internal NetworkD Error: #{ex.message}"
    ensure
      client.close rescue nil
    end
  end
end
