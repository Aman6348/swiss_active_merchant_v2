$LOAD_PATH.push File.expand_path('../lib', __FILE__)
require 'active_merchant/version'

Gem::Specification.new do |s|
  s.platform     = Gem::Platform::RUBY
  s.name         = 'swiss-crm-activemerchant-v2'
  s.version      = ActiveMerchant::VERSION
  s.summary      = 'Framework and tools for dealing with credit card transactions.'
  s.description  = 'Active Merchant is a simple payment abstraction library used in and sponsored by Shopify. It is written by Tobias Luetke, Cody Fauser, and contributors. The aim of the project is to feel natural to Ruby users and to abstract as many parts as possible away from the user to offer a consistent interface across all supported gateways.'
  s.license      = 'MIT'

  s.author = 'Tobias Luetke'
  s.email = 'tobi@leetsoft.com'
  s.homepage = 'http://activemerchant.org/'

  s.required_ruby_version = '>= 2.5'

  s.files = Dir['CHANGELOG', 'README.md', 'MIT-LICENSE', 'CONTRIBUTORS', 'lib/**/*', 'vendor/**/*']
  s.require_path = 'lib'

  s.metadata['allowed_push_host'] = 'https://rubygems.org'

  s.has_rdoc = true if Gem::VERSION < '1.7.0'

  s.add_dependency('activesupport', '>= 4.2')
  s.add_dependency('builder', '>= 2.1.2', '< 4.0.0')
  s.add_dependency('i18n', '>= 0.6.9')
  s.add_dependency('nokogiri', '~> 1.4')
  s.add_dependency('rexml', '~> 3.2.5')
  s.add_dependency 'swiss-klarna_proxy', '1.0'

  s.add_development_dependency('mocha', '~> 1')
  s.add_development_dependency('pry')
  s.add_development_dependency('pry-byebug')
  s.add_development_dependency('rake')
  s.add_development_dependency('test-unit', '~> 3')
  s.add_development_dependency('thor')
end
