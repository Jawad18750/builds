# Waits for App Store Connect to process an uploaded build, then submits it for review with
# release on approval.
#
#   ruby scripts/submit.rb <IOS|MAC_OS> <bundle id> <version> <build number> <release notes file>
#
# Apple allows one open submission per app. One already waiting (or in review, or with
# unresolved issues) is withdrawn first, and its version record, now editable again, is
# reused under the new version string: it keeps the review contact and the other answers it
# was submitted with. Only when there is no editable version is a new one created, and a new
# record needs the review contact, from APP_REVIEW_CONTACT_* (secrets, never printed).
#
# Runs on Linux: this is waiting and API calls. Prints states and version strings only.
require "spaceship"

$stdout.sync = true

platform, bundle, version, build_number, notes_path = ARGV
abort "usage: submit.rb <IOS|MAC_OS> <bundle> <version> <build> <notes file>" unless notes_path
notes = File.read(notes_path).strip
abort "no release notes in #{notes_path}" if notes.empty?

Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
  key_id: ENV.fetch("ASC_KEY_ID"),
  issuer_id: ENV.fetch("ASC_ISSUER_ID"),
  key: ENV.fetch("ASC_API_KEY_P8")
)
app = Spaceship::ConnectAPI::App.find(bundle) || abort("no app #{bundle}")
ios = platform # the name stays: every call below takes it as the platform

# 1. Apple's processing.
deadline = Time.now + 90 * 60
last = nil
build = nil
# By build number, then by platform: iOS and the Mac share build numbers, and a platform
# filter on the query side has been seen to miss a Mac build that was there.
find_build = lambda do
  Spaceship::ConnectAPI.get_builds(
    filter: { app: app.id, version: build_number }, includes: "preReleaseVersion",
    sort: "-uploadedDate", limit: 20
  ).to_models.find do |b|
    b.pre_release_version && b.pre_release_version.platform.to_s == platform &&
      b.pre_release_version.version.to_s == version
  end
end
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

# 2. The submission already open, withdrawn so this build takes its place.
if (open = app.get_in_progress_review_submission(platform: ios))
  puts "withdrawing the open submission (#{open.state})"
  open.cancel_submission
  60.times do
    v = app.get_edit_app_store_version(platform: ios)
    break if v && !%w[WAITING_FOR_REVIEW IN_REVIEW].include?(v.app_store_state.to_s)
    sleep 15
  end
end

# 3. The version record: the editable one, renamed, or a new one.
record = app.get_edit_app_store_version(platform: ios)
if record.nil?
  contact = %w[FIRST_NAME LAST_NAME EMAIL PHONE].to_h { |k| [k, ENV["APP_REVIEW_CONTACT_#{k}"].to_s] }
  abort "a new version record needs APP_REVIEW_CONTACT_* secrets" if contact.values.any?(&:empty?)
  puts "creating version #{version}"
  Spaceship::ConnectAPI.post_app_store_version(app_id: app.id, attributes: {
    platform: ios, versionString: version
  })
  record = app.get_edit_app_store_version(platform: ios) || abort("the new version is not editable")
  detail = begin
    record.fetch_app_store_review_detail
  rescue StandardError
    nil
  end
  attrs = {
    contactFirstName: contact["FIRST_NAME"], contactLastName: contact["LAST_NAME"],
    contactEmail: contact["EMAIL"], contactPhone: contact["PHONE"], demoAccountRequired: false
  }
  if detail
    detail.update(attributes: attrs)
  else
    record.create_app_store_review_detail(attributes: attrs)
  end
  puts "review contact set"
elsif record.version_string != version
  puts "reusing version record #{record.version_string} (#{record.app_store_state}) as #{version}"
  record.update(attributes: { versionString: version })
  record = app.get_edit_app_store_version(platform: ios)
end

record.update(attributes: { releaseType: "AFTER_APPROVAL" })
record.select_build(build_id: build.id)
puts "#{version}: build #{build_number} selected, release on approval"

locs = record.get_app_store_version_localizations
abort "the version has no localizations" if locs.empty?
locs.each do |loc|
  loc.update(attributes: { whatsNew: notes })
  puts "what's new set for #{loc.locale}"
end

# 4. Submit: the ready submission Apple may already hold, or a new one.
submission = app.get_ready_review_submission(platform: ios) || app.create_review_submission(platform: ios)
begin
  submission.add_app_store_version_to_review_items(app_store_version_id: record.id)
rescue StandardError => e
  # Already an item of this submission (a retried run): fine, anything else is not.
  raise unless e.message.to_s =~ /already|duplicate|exists/i
end
submission.submit_for_review
puts "#{version} (#{build_number}) submitted for review, release on approval"
