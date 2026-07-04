require_relative "lib/angarium/version"

Gem::Specification.new do |spec|
  spec.name        = "angarium"
  spec.version     = Angarium::VERSION
  spec.authors     = ["TheDumbTechGuy"]
  spec.email       = ["sfroelich01@gmail.com"]
  spec.homepage    = "https://github.com/radioactive-labs/angarium"
  spec.summary     = "Outbound webhooks for Rails: signed, retried, subscription-based delivery."
  spec.description = "A mountable Rails engine that delivers outbound webhooks with HMAC signing, automatic retries with exponential backoff, and per-endpoint event subscriptions."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  # Set to a private/paid gem host if selling through one; keep rubygems.org for public release.
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = "https://github.com/radioactive-labs/angarium"
  spec.metadata["changelog_uri"] = "https://github.com/radioactive-labs/angarium/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 7.1", "< 9"
  spec.add_dependency "httpx", "~> 1.0"
end
