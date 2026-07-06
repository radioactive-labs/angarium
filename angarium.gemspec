require_relative "lib/angarium/version"

Gem::Specification.new do |spec|
  spec.name = "angarium"
  spec.version = Angarium::VERSION
  spec.authors = ["TheDumbTechGuy"]
  spec.email = ["sfroelich01@gmail.com"]
  spec.homepage = "https://github.com/radioactive-labs/angarium"
  spec.summary = "Outbound webhooks for Rails — Standard Webhooks signing, retries with backoff, secret rotation, SSRF protection, and a log of every attempt. Everything the hand-rolled version is missing."
  spec.description = <<~DESC.tr("\n", " ").strip
    The moment "just POST from a background job" ships to production, the gaps
    start showing: your customers need signatures they can verify, failed
    deliveries need to back off and retry for hours, secrets need to rotate
    without downtime, an endpoint URL shouldn't be able to reach your internal
    network, and sooner or later someone asks "did we actually send it?".
    Angarium is a Rails engine that handles all of it, and signs to the Standard
    Webhooks spec, so your receivers verify with off-the-shelf libraries in any
    language and you never write verification docs of your own. That conformance
    is enforced in CI: any drift from the spec fails the build.
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  # Set to a private/paid gem host if selling through one; keep rubygems.org for public release.
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = "https://github.com/radioactive-labs/angarium"
  spec.metadata["changelog_uri"] = "https://github.com/radioactive-labs/angarium/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/radioactive-labs/angarium/issues"
  spec.metadata["documentation_uri"] = "https://github.com/radioactive-labs/angarium#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md", "SECURITY.md"]
  end

  spec.add_dependency "rails", ">= 7.1", "< 9"
  spec.add_dependency "httpx", "~> 1.0"
end
