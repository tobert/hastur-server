require "rubygems"
require "bundler"
#Bundler.require(:default, :development)

# For testing Hastur components, use the local version *first*.
$LOAD_PATH.unshift File.join(File.dirname(__FILE__), "..", "..", "lib")

require "hastur/test/topology_helper"
