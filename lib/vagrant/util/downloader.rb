require "uri"

require "log4r"

require "vagrant/util/busy"
require "vagrant/util/platform"
require "vagrant/util/subprocess"

module Vagrant
  module Util
    # This class downloads files using various protocols by subprocessing
    # to cURL. cURL is a much more capable and complete download tool than
    # a hand-rolled Ruby library, so we defer to its expertise.
    class Downloader
      # Custom user agent provided to cURL so that requests to URL shorteners
      # are properly tracked.
      USER_AGENT = "Vagrant/#{VERSION}"

      attr_reader :source
      attr_reader :destination

      def initialize(source, destination, options=nil)
        options     ||= {}

        @logger      = Log4r::Logger.new("vagrant::util::downloader")
        @source      = source.to_s
        @destination = destination.to_s

        begin
          url = URI.parse(@source)
          if url.scheme && url.scheme.start_with?("http") && url.user
            auth = "#{url.user}"
            auth += ":#{url.password}" if url.password
            url.user = nil
            url.password = nil
            options[:auth] ||= auth
            @source = url.to_s
          end
        rescue URI::InvalidURIError
          # Ignore, since its clearly not HTTP
        end

        # Get the various optional values
        @auth        = options[:auth]
        @ca_cert     = options[:ca_cert]
        @ca_path     = options[:ca_path]
        @continue    = options[:continue]
        @headers     = options[:headers]
        @insecure    = options[:insecure]
        @ui          = options[:ui]
        @client_cert = options[:client_cert]
      end

      # This executes the actual download, downloading the source file
      # to the destination with the given options used to initialize this
      # class.
      #
      # If this method returns without an exception, the download
      # succeeded. An exception will be raised if the download failed.
      def download!
        options, subprocess_options = self.options
        options += ["--output", @destination]
        options << @source

        # This variable can contain the proc that'll be sent to
        # the subprocess execute.
        data_proc = nil

        if @ui
          # If we're outputting progress, then setup the subprocess to
          # tell us output so we can parse it out.
          subprocess_options[:notify] = :stderr

          progress_data = ""
          progress_regexp = /(\r(.+?))\r/

          # Setup the proc that'll receive the real-time data from
          # the downloader.
          data_proc = Proc.new do |type, data|
            # Type will always be "stderr" because that is the only
            # type of data we're subscribed for notifications.

            # Accumulate progress_data
            progress_data << data

            while true
              # If we have a full amount of column data (two "\r") then
              # we report new progress reports. Otherwise, just keep
              # accumulating.
              match = progress_regexp.match(progress_data)
              break if !match
              data = match[2]
              progress_data.gsub!(match[1], "")

              # Ignore the first \r and split by whitespace to grab the columns
              columns = data.strip.split(/\s+/)

              # COLUMN DATA:
              #
              # 0 - % total
              # 1 - Total size
              # 2 - % received
              # 3 - Received size
              # 4 - % transferred
              # 5 - Transferred size
              # 6 - Average download speed
              # 7 - Average upload speed
              # 9 - Total time
              # 9 - Time spent
              # 10 - Time left
              # 11 - Current speed

              output = "Progress: #{columns[0]}% (Rate: #{columns[11]}/s, Estimated time remaining: #{columns[10]})"
              @ui.clear_line
              @ui.detail(output, new_line: false)
            end
          end
        end

        @logger.info("Downloader starting download: ")
        @logger.info("  -- Source: #{@source}")
        @logger.info("  -- Destination: #{@destination}")

        begin
          execute_curl(options, subprocess_options, &data_proc)
        ensure
          # If we're outputting to the UI, clear the output to
          # avoid lingering progress meters.
          if @ui
            @ui.clear_line

            # Windows doesn't clear properly for some reason, so we just
            # output one more newline.
            @ui.detail("") if Platform.windows?
          end
        end

        # Everything succeeded
        true
      end

      # Does a HEAD request of the URL and returns the output.
      def head
        options, subprocess_options = self.options
        options.unshift("-I")
        options << @source

        @logger.info("HEAD: #{@source}")
        result = execute_curl(options, subprocess_options)
        result.stdout
      end

      protected

      def execute_curl(options, subprocess_options, &data_proc)
        options = options.dup
        options << subprocess_options

        # Create the callback that is called if we are interrupted
        interrupted  = false
        int_callback = Proc.new do
          @logger.info("Downloader interrupted!")
          interrupted = true
        end

        # Execute!
        result = Busy.busy(int_callback) do
          Subprocess.execute("curl", *options, &data_proc)
        end

        # If the download was interrupted, then raise a specific error
        raise Errors::DownloaderInterrupted if interrupted

        # If it didn't exit successfully, we need to parse the data and
        # show an error message.
        if result.exit_code != 0
          @logger.warn("Downloader exit code: #{result.exit_code}")
          parts    = result.stderr.split(/\n*curl:\s+\(\d+\)\s*/, 2)
          parts[1] ||= ""
          raise Errors::DownloaderError, message: parts[1].chomp
        end

        result
      end

      # Returns the varoius cURL and subprocess options.
      #
      # @return [Array<Array, Hash>]
      def options
        # Build the list of parameters to execute with cURL
        options = [
          "--fail",
          "--location",
          "--max-redirs", "10",
          "--user-agent", USER_AGENT,
        ]

        options += ["--cacert", @ca_cert] if @ca_cert
        options += ["--capath", @ca_path] if @ca_path
        options += ["--continue-at", "-"] if @continue
        options << "--insecure" if @insecure
        options << "--cert" << @client_cert if @client_cert
        options << "-u" << @auth if @auth

        if @headers
          Array(@headers).each do |header|
            options << "-H" << header
          end
        end

        # Specify some options for the subprocess
        subprocess_options = {}

        # If we're in Vagrant, then we use the packaged CA bundle
        if Vagrant.in_installer?
          subprocess_options[:env] ||= {}
          subprocess_options[:env]["CURL_CA_BUNDLE"] =
            File.expand_path("cacert.pem", ENV["VAGRANT_INSTALLER_EMBEDDED_DIR"])
        end

        return [options, subprocess_options]
      end
    end
  end
end
