# frozen_string_literal: true

module Jekyll
  module Spaceship
  end
end

require 'jekyll-spaceship/cores/logger'
require 'jekyll-spaceship/cores/config'
require 'jekyll-spaceship/cores/processor'
require 'jekyll-spaceship/processors/mermaid-processor'

RSpec.describe Jekyll::Spaceship::MermaidProcessor do
  subject(:processor) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@config, config)
      instance.instance_variable_set(:@logger, logger)
    end
  end

  let(:config) do
    {
      'mode' => mode,
      'css' => { 'class' => 'mermaid' },
      'config' => { 'theme' => 'default' },
      'mmdc_args' => [],
      'src' => 'https://mermaid.ink/svg/'
    }
  end
  let(:mode) { 'default' }
  let(:logger) { instance_double(Jekyll::Spaceship::Logger, :log => nil) }
  let(:url) { 'https://example.test/diagram.svg' }
  let(:remote) { { 'type' => 'image/svg+xml', 'body' => '<svg />' } }

  before do
    allow(processor).to receive(:get_url).and_return(url)
    allow(described_class).to receive(:make_img_tag) { |data| data }
  end

  describe '#handle_mermaid' do
    context 'in pre-build mode' do
      let(:mode) { 'pre-build' }

      it 'uses locally rendered SVG data without making a network request' do
        local = { 'type' => 'image/svg+xml', 'body' => '<svg>local</svg>' }
        allow(processor).to receive(:render_mermaid_locally).and_return(local)
        expect(described_class).not_to receive(:fetch_img_data)

        expect(processor.handle_mermaid("graph TD\nA-->B")).to eq(local.merge('class' => 'mermaid'))
      end

      it 'falls back from local rendering to pre-fetch and then to the URL' do
        allow(processor).to receive(:render_mermaid_locally).and_return(nil)
        allow(described_class).to receive(:fetch_img_data).with(url).and_return(nil)

        expect(processor.handle_mermaid('graph TD; A-->B')).to eq(
          'type' => 'url', 'body' => url, 'class' => 'mermaid'
        )
      end

      it 'uses pre-fetched data when local rendering fails' do
        allow(processor).to receive(:render_mermaid_locally).and_return(nil)
        allow(described_class).to receive(:fetch_img_data).with(url).and_return(remote)

        expect(processor.handle_mermaid('graph TD; A-->B')).to eq(remote.merge('class' => 'mermaid'))
      end
    end

    context 'in pre-fetch mode' do
      let(:mode) { 'pre-fetch' }

      it 'pre-fetches the remote image' do
        allow(described_class).to receive(:fetch_img_data).with(url).and_return(remote)
        expect(processor.handle_mermaid('graph TD; A-->B')).to eq(remote.merge('class' => 'mermaid'))
      end
    end

    it 'uses a URL in default mode' do
      expect(described_class).not_to receive(:fetch_img_data)
      expect(processor.handle_mermaid('graph TD; A-->B')).to eq(
        'type' => 'url', 'body' => url, 'class' => 'mermaid'
      )
    end
  end

  describe '#render_mermaid_locally' do
    before do
      stub_const('JekyllMermaidPrebuild', Module.new)
      wrapper = Class.new do
        def self.available?; end
        def self.render(_code, _path); end
      end
      wrapper.const_set(:MMDC_COMMAND, 'mmdc')
      stub_const('JekyllMermaidPrebuild::MmdcWrapper', wrapper)
      allow(processor).to receive(:require).with('jekyll-mermaid-prebuild').and_return(true)
    end

    it 'renders through jekyll-mermaid-prebuild using a project-local CLI' do
      allow(processor).to receive(:local_mermaid_cli_dir).and_return('/project/node_modules/.bin')
      allow(processor).to receive(:with_mermaid_cli_path).and_yield
      allow(JekyllMermaidPrebuild::MmdcWrapper).to receive(:render) do |_code, path|
        File.write(path, '<?xml version="1.0"?><svg>local</svg>')
        true
      end

      expect(processor.render_mermaid_locally('graph TD; A-->B')).to eq(
        'type' => 'image/svg+xml', 'body' => '<?xml version="1.0"?><svg>local</svg>'
      )
    end

    it 'uses a globally available CLI' do
      allow(processor).to receive(:local_mermaid_cli_dir).and_return(nil)
      allow(JekyllMermaidPrebuild::MmdcWrapper).to receive(:available?).and_return(true)
      allow(JekyllMermaidPrebuild::MmdcWrapper).to receive(:render).and_return(false)

      expect(processor.render_mermaid_locally('invalid')).to be_nil
    end

    it 'passes configured arguments directly to mmdc' do
      config['mmdc_args'] = ['--puppeteerConfigFile', '.github/puppeteer-config.json']
      allow(processor).to receive(:local_mermaid_cli_dir).and_return('/project/node_modules/.bin')
      allow(processor).to receive(:with_mermaid_cli_path).and_yield
      expect(JekyllMermaidPrebuild::MmdcWrapper).not_to receive(:render)
      allow(Open3).to receive(:capture3) do |*command|
        File.write(command[4], '<svg>configured</svg>')
        ['', '', instance_double(Process::Status, :success? => true)]
      end

      expect(processor.render_mermaid_locally('graph TD; A-->B')).to eq(
        'type' => 'image/svg+xml', 'body' => '<svg>configured</svg>'
      )
      expect(Open3).to have_received(:capture3).with(
        'mmdc', '-i', kind_of(String), '-o', kind_of(String), '-e', 'svg',
        '--puppeteerConfigFile', '.github/puppeteer-config.json'
      )
    end

    it 'returns nil when mmdc fails with configured arguments' do
      config['mmdc_args'] = ['--puppeteerConfigFile', 'puppeteer-config.json']
      allow(processor).to receive(:local_mermaid_cli_dir).and_return(nil)
      allow(JekyllMermaidPrebuild::MmdcWrapper).to receive(:available?).and_return(true)
      allow(Open3).to receive(:capture3).and_return(
        ['', 'Chrome failed', instance_double(Process::Status, :success? => false)]
      )

      expect(processor.render_mermaid_locally('graph TD; A-->B')).to be_nil
    end

    it 'logs and falls back when no CLI is available' do
      allow(processor).to receive(:local_mermaid_cli_dir).and_return(nil)
      allow(JekyllMermaidPrebuild::MmdcWrapper).to receive(:available?).and_return(false)

      expect(logger).to receive(:log).with('mmdc not found; falling back to pre-fetch')
      expect(processor.render_mermaid_locally('graph TD')).to be_nil
    end

    it 'logs the error and falls back when the integration raises' do
      allow(processor).to receive(:local_mermaid_cli_dir).and_raise(Errno::ENOENT, 'mmdc')

      expect(logger).to receive(:log).with(/local Mermaid rendering failed: .*mmdc.*falling back/)
      expect(processor.render_mermaid_locally('graph TD')).to be_nil
    end
  end

  describe '#local_mermaid_cli_dir' do
    it 'finds mmdc in the Jekyll project before the current directory' do
      site = double(:site, :source => '/site')
      processor.instance_variable_set(:@page, double(:page, :site => site))
      allow(File).to receive(:file?).and_return(true)
      allow(File).to receive(:executable?).and_return(true)

      expect(processor.local_mermaid_cli_dir).to eq('/site/node_modules/.bin')
    end

    it 'returns nil when a local executable does not exist' do
      allow(File).to receive(:file?).and_return(false)
      expect(processor.local_mermaid_cli_dir).to be_nil
    end
  end

  describe '#with_mermaid_cli_path' do
    it 'leaves PATH unchanged for a global executable' do
      original = ENV['PATH']
      expect(processor.with_mermaid_cli_path(nil) { ENV['PATH'] }).to eq(original)
    end

    it 'prepends the local bin directory and always restores PATH' do
      original = ENV['PATH']
      expect do
        processor.with_mermaid_cli_path('/project/node_modules/.bin') do
          expect(ENV['PATH']).to start_with('/project/node_modules/.bin')
          raise 'render failed'
        end
      end.to raise_error('render failed')
      expect(ENV['PATH']).to eq(original)
    end
  end
end
