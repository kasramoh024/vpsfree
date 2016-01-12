require 'eventmachine'
require 'em-http'
require 'time'
require 'json'
require 'base64'
require 'terminal-size'

module VpsFree::CLI::Commands
  class VpsRemoteControl < HaveAPI::CLI::Command
    cmd :vps, :remote_console
    args 'VPS_ID'
    desc 'Open VPS remote console'

    class InputHandler < EventMachine::Connection
      attr_accessor :buffer

      def initialize
        @buffer = ''
        @end_seq = ["\e", "."]
        @end_i = 0
      end

      def receive_data(data)
        if data == @end_seq[ @end_i ]
          if @end_i == @end_seq.size-1
            EM.stop
            return
          end

          @end_i += 1

        else
          @end_i = 0
        end

        @buffer += data
      end
    end

    def options(opts)
      @opts = {
          rate: 0.05
      }

      opts.on('--refresh-rate MSEC', 'How often send and receive data, defaults to 50 ms') do |r|
        @opts[:rate] = r.to_i / 1000.0
      end
    end

    def exec(args)
      if args.empty?
        puts "provide VPS ID as an argument"
        exit(false)
      end

      vps_id = args.first.to_i

      write "Locating VPS.."
      vps = @api.vps.show(vps_id, meta: { includes: 'node__location' })
      puts "  VPS is on #{vps.node.domain_name}, located in #{vps.node.location.label}."
      puts "Console router URL is #{vps.node.location.remote_console_server}"

      write "Obtaining authentication token..."

      t = vps.console_token(vps_id).create
      @token = t.token

      puts "  token expires at #{Time.iso8601(t.expiration).localtime}"
      puts "Connecting to remote console..."
      puts "Press ESC . to exit"
      puts

      raw_mode do
        EventMachine.run do
          @input = EventMachine.open_keyboard(InputHandler)

          @http = EventMachine::HttpRequest.new(
              "#{vps.node.location.remote_console_server}/console/feed/#{vps_id}"
          )
          communicate
        end
      end
    end

    protected
    def write(s)
      $stdout.write(s)
      $stdout.flush
    end

    def raw_mode
      state = `stty -g`
      `stty raw -echo -icanon -isig`

      pid = Process.fork do
        @size = Terminal.size!
        
        Signal.trap('WINCH') do
          @size = Terminal.size!
        end

        yield
      end

      Process.wait(pid) 

      `stty #{state}`
      puts
    end

    def communicate
      post = @http.post(
          body: {
              session: @token,
              keys: @input.buffer,
              width: @size[:width],
              height: @size[:height],
          },
          keepalive: true
      )

      @input.buffer = ''

      post.errback do
        puts "Error: connection to console router failed"
        EventMachine.stop
      end

      post.callback do
        ret = JSON.parse(post.response, symbolize_names: true)
        
        unless ret[:session]
          $stdout.write(ret[:data])
          puts "\nSession closed."
          EM.stop
          next
        end

        $stdout.write(Base64.decode64(ret[:data]))

        EM.add_timer(@opts[:rate]) { communicate }
      end
    end
  end
end