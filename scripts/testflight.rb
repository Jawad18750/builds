# Waits for App Store Connect to process an uploaded build, then hands it to TestFlight
# testers: What to Test in every beta localization, beta app review when an external group
# is named (Apple reviews the first build of a version; later builds of it usually pass at
# once), then the groups themselves.
#
#   ruby scripts/testflight.rb <IOS|MAC_OS> <bundle id> <version> <build number> <notes file> <group[,group]>
#
# A group that receives every build (the internal one) needs nothing and need not be named.
# Export compliance comes from the app's Info.plist (ITSAppUsesNonExemptEncryption = NO); a
# build that arrives without an answer gets "no non-exempt encryption" here, as pilot does.
#
# Runs on Linux: this is waiting and API calls. Prints states and group names only.
require "spaceship"

$stdout.sync = true

platform, bundle, version, build_number, notes_path, group_names = ARGV
abort "usage: testflight.rb <IOS|MAC_OS> <bundle> <version> <build> <notes file> <groups>" unless group_names
notes = File.read(notes_path).strip
abort "no release notes in #{notes_path}" if notes.empty?
wanted = group_names.split(",").map(&:strip).reject(&:empty?)
abort "no TestFlight group named" if wanted.empty?

Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
  key_id: ENV.fetch("ASC_KEY_ID"),
  issuer_id: ENV.fetch("ASC_ISSUER_ID"),
  key: ENV.fetch("ASC_API_KEY_P8")
)
app = Spaceship::ConnectAPI::App.find(bundle) || abort("no app #{bundle}")

# By build number, then by platform, as in submit.rb: iOS and the Mac share build numbers.
find_build = lambda do
  Spaceship::ConnectAPI.get_builds(
    filter: { app: app.id, version: build_number }, includes: "preReleaseVersion,buildBetaDetail",
    sort: "-uploadedDate", limit: 20
  ).to_models.find do |b|
    b.pre_release_version && b.pre_release_version.platform.to_s == platform &&
      b.pre_release_version.version.to_s == version
  end
end
external_state = ->(b) { b.build_beta_detail ? b.build_beta_detail.external_build_state.to_s : "UNKNOWN" }

# 1. Apple's processing.
deadline = Time.now + 90 * 60
last = nil
build = nil
loop do
  build = find_build.call
  state = build ? build.processing_state : "NOT_VISIBLE_YET"
  puts "#{platform} #{version} (#{build_number}): #{state}" if state != last
  last = state
  break if state == "VALID"
  abort "#{version} (#{build_number}) is #{state} on App Store Connect" if %w[FAILED INVALID].include?(state)
  abort "#{version} (#{build_number}) was not processed within 90 minutes" if Time.now > deadline
  sleep 60
end

# 2. Export compliance, when the build carries no answer of its own.
if build.uses_non_exempt_encryption.nil?
  build.update(attributes: { usesNonExemptEncryption: false })
  puts "export compliance answered: no non-exempt encryption"
  20.times do
    build = find_build.call
    break unless external_state.call(build) == "MISSING_EXPORT_COMPLIANCE"
    sleep 15
  end
end

# 3. What to Test: every localization the build has, else the app's beta localizations, else
# its primary language.
locs = build.get_beta_build_localizations
if locs.empty?
  locales = app.get_beta_app_localizations.map(&:locale)
  locales = [app.primary_locale] if locales.empty?
  locales.compact.uniq.each do |locale|
    Spaceship::ConnectAPI.post_beta_build_localizations(build_id: build.id, attributes: { locale: locale, whatsNew: notes })
    puts "what to test set for #{locale}"
  end
else
  locs.each do |loc|
    Spaceship::ConnectAPI.patch_beta_build_localizations(localization_id: loc.id, attributes: { whatsNew: notes })
    puts "what to test set for #{loc.locale}"
  end
end

# 4. Beta app review, then the groups.
all = app.get_beta_groups
groups = wanted.map { |n| all.find { |g| g.name == n } || abort("no TestFlight group named #{n}") }
if groups.any? { |g| !g.is_internal_group }
  state = external_state.call(build)
  if state == "READY_FOR_BETA_SUBMISSION"
    build.post_beta_app_review_submission
    puts "submitted for beta app review"
  else
    puts "beta app review: #{state}, nothing to submit"
  end
end
build.add_beta_groups(beta_groups: groups)
puts "#{version} (#{build_number}) added to #{groups.map(&:name).join(', ')}"
puts "beta app review: #{external_state.call(find_build.call)}"
