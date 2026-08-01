# frozen_string_literal: true

require "net/http"
require "base64"
require "tempfile"

module Jekyll::Spaceship
  class MermaidProcessor < Processor
    exclude :none

    def self.config
      {
        'mode' => 'default',
        'syntax' => {
          'code' => 'mermaid!',
          'custom' => ['@startmermaid', '@endmermaid']
        },
        'css' => {
          'class' => 'mermaid'
        },
        'config': {
          'theme' => 'default'
        },
        'src' => 'https://mermaid.ink/svg/'
      }
    end

    def on_handle_markdown(content)
      # match custom mermaid block and code block
      syntax = self.config['syntax']
      code_name = syntax['code']
      custom = syntax['custom'][-2, 2]

      patterns = [
        /((`{3,})\s*#{code_name}((?:.|\n)*?)\2)/,
        /((?<!\\)(#{custom[0]})((?:.|\n)*?)(?<!\\)(#{custom[1]}))/
      ]

      patterns.each do |pattern|
        content = handle_mermaid_block(pattern, content)
      end

      # handle escape custom mermaid block
      content.gsub(/\\(#{custom[0]}|#{custom[1]})/, '\1')
    end

    def handle_mermaid_block(pattern, content)
      content.scan pattern do |match|
        match = match.select { |m| not m.nil? }
        block = match[0]
        code = match[2]

        self.handled = true

        content = content.gsub(
          block,
          handle_mermaid(code)
        )
      end
      content
    end

    def handle_mermaid(code)
      # Handle extra empty lines, otherwise it would cause error
      code = code.gsub(/\n\s*\n/, "\n%%-\n")

      # encode to UTF-8
      code = code.encode('UTF-8')

      # render mode
      mode = self.config['mode']

      data = render_mermaid_locally(code) if mode == 'pre-build'
      if data.nil?
        url = get_url(code)

        data = self.class.fetch_img_data(url) \
          if ['pre-build', 'pre-fetch'].include?(mode)

        if data.nil?
          data = { 'type' => 'url', 'body' => url }
        end
      end

      # return img tag
      data['class'] = self.config['css']['class']
      self.class.make_img_tag(data)
    end

    def render_mermaid_locally(code)
      require 'jekyll-mermaid-prebuild'

      cli_dir = local_mermaid_cli_dir
      unless cli_dir || JekyllMermaidPrebuild::MmdcWrapper.available?
        logger.log 'mmdc not found; falling back to pre-fetch'
        return
      end

      svg = Tempfile.new(['jekyll-spaceship-mermaid', '.svg'])
      begin
        rendered = with_mermaid_cli_path(cli_dir) do
          JekyllMermaidPrebuild::MmdcWrapper.render(code, svg.path)
        end
        return unless rendered

        { 'type' => 'image/svg+xml', 'body' => File.read(svg.path) }
      ensure
        svg.close!
      end
    rescue LoadError, StandardError => error
      logger.log "local Mermaid rendering failed: #{error.message}; falling back to pre-fetch"
      nil
    end

    def local_mermaid_cli_dir
      local_mermaid_cli_roots.each do |root|
        bin = File.join(root, 'node_modules', '.bin')
        return bin if mermaid_cli_executable?(bin)
      end
      nil
    end

    def local_mermaid_cli_roots
      roots = [Dir.pwd]
      site = page.site if page && page.respond_to?(:site)
      roots.unshift(site.source) if site
      roots.uniq
    end

    def mermaid_cli_executable?(bin)
      command = File.join(bin, Gem.win_platform? ? 'mmdc.cmd' : 'mmdc')
      File.file?(command) && File.executable?(command)
    end

    def with_mermaid_cli_path(cli_dir)
      return yield unless cli_dir

      original_path = ENV['PATH']
      ENV['PATH'] = [cli_dir, original_path].compact.join(File::PATH_SEPARATOR)
      begin
        yield
      ensure
        ENV['PATH'] = original_path
      end
    end

    def get_url(code)
      src = self.config['src']

      # wrap code
      code = {
        'code' => code.gsub(/^\s*|\s*$/, ''),
        'mermaid' => config['config']
      }.to_json

      # set default method
      src += '{code}' if src.match(/\{.*\}/).nil?

      # encode to base64 string
      if src.include?('{code}')
        code = Base64.urlsafe_encode64(code, padding: false)
        return src.gsub('{code}', code)
      else
        raise "No supported src ! #{src}"
      end
    end
  end
end
