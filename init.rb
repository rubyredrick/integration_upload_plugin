rails_version =  Rails::VERSION::STRING 
raise "Rails version is #{rails_version}. The integration_upload_plugin requires rails version 2.0.2, and is unneeded for >2.0.2" unless rails_version == '2.0.2'

require 'action_controller/integration'

module ::ActionController
  module Integration
    class Session

      class MultiPartNeededException < Exception
      end

      private
      # Performs the actual request.
      def process(method, path, parameters = nil, headers = nil)
        data = requestify(parameters)
        path = interpret_uri(path) if path =~ %r{://}
        path = "/#{path}" unless path[0] == ?/
        @path = path
        env = {}

        if method == :get
          env["QUERY_STRING"] = data
          data = nil
        end

        env.update(
        "REQUEST_METHOD" => method.to_s.upcase,
        "REQUEST_URI"    => path,
        "HTTP_HOST"      => host,
        "REMOTE_ADDR"    => remote_addr,
        "SERVER_PORT"    => (https? ? "443" : "80"),
        "CONTENT_TYPE"   => "application/x-www-form-urlencoded",
        "CONTENT_LENGTH" => data ? data.length.to_s : nil,
        "HTTP_COOKIE"    => encode_cookies,
        "HTTPS"          => https? ? "on" : "off",
        "HTTP_ACCEPT"    => accept
        )

        (headers || {}).each do |key, value|
          key = key.to_s.upcase.gsub(/-/, "_")
          key = "HTTP_#{key}" unless env.has_key?(key) || key =~ /^HTTP_/
          env[key] = value
        end

        unless ActionController::Base.respond_to?(:clear_last_instantiation!)
          ActionController::Base.module_eval { include ControllerCapture }
        end

        ActionController::Base.clear_last_instantiation!

        cgi = StubCGI.new(env, data)
        Dispatcher.dispatch(cgi, ActionController::CgiRequest::DEFAULT_SESSION_OPTIONS, cgi.stdoutput)
        @result = cgi.stdoutput.string
        @request_count += 1

        @controller = ActionController::Base.last_instantiation
        @request = @controller.request
        @response = @controller.response

        # Decorate the response with the standard behavior of the TestResponse
        # so that things like assert_response can be used in integration
        # tests.
        @response.extend(TestResponseBehavior)

        @html_document = nil

        parse_result
        return status
      rescue MultiPartNeededException 
        boundary = "----------XnJLe9ZIbbGUYtzPQJ16u1" 
        status = process(method, path, multipart_body(parameters, boundary), (headers || {}).merge({"CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}"})) 
        return status
      end

      # Convert the given parameters to a request string. The parameters may
      # be a string, +nil+, or a Hash.
      def requestify(parameters, prefix=nil)
        if TestUploadedFile === parameters
          raise MultiPartNeededException
        elsif Hash === parameters
          return nil if parameters.empty?
          parameters.map { |k,v| requestify(v, name_with_prefix(prefix, k)) }.join("&")
        elsif Array === parameters
          parameters.map { |v| requestify(v, name_with_prefix(prefix, "")) }.join("&")
        elsif prefix.nil?
          parameters
        else
          "#{CGI.escape(prefix)}=#{CGI.escape(parameters.to_s)}"
        end
      end

      def multipart_requestify(params, first=true) 
        returning Hash.new do |p| 
          params.each do |key, value| 
            k = first ? CGI.escape(key.to_s) : "[#{CGI.escape(key.to_s)}]" 
            if Hash === value 
              multipart_requestify(value, false).each do |subkey, subvalue| 
                p[k + subkey] = subvalue 
              end 
            else 
              p[k] = value 
            end 
          end 
        end 
      end 

      def multipart_body(params, boundary) 
        multipart_requestify(params).map do |key, value| 
          if value.respond_to?(:original_filename) 
            File.open(value.path) do |f| 
              <<-EOF
--#{boundary}\r
Content-Disposition: form-data; name="#{key}"; filename="#{CGI.escape(value.original_filename)}"\r
Content-Type: #{value.content_type}\r
Content-Length: #{File.stat(value.path).size}\r
\r
#{f.read}\r
EOF
            end 
          else 
            <<-EOF
--#{boundary}\r
Content-Disposition: form-data; name="#{key}"\r
\r
#{value}\r
EOF
          end 
        end.join("")+"--#{boundary}--\r"
      end
    end
  end
end
