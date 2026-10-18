# Waits for App Store Connect to process an uploaded build, then submits it for review with
# release on approval.
#
#   ruby scripts/submit.rb <IOS|MAC_OS> <bundle id> <version> <build number> <release notes file>
#   (SHOTS_DIR=<dir of locale folders> also replaces the store screenshots before submitting)
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

# 3b. Store screenshots, only when this run made them: SHOTS_DIR holds <locale>/*.png. Each
# display type found there (by pixel size) is replaced as a whole, in file-name order; types
# that are not there are left as they are. Apple accepts screenshot changes only on an
# editable version, which is why this happens here, after the record above and before submit.
SLOTS = {
  [2064, 2752] => "APP_IPAD_PRO_3GEN_129", [2048, 2732] => "APP_IPAD_PRO_3GEN_129",
  [1320, 2868] => "APP_IPHONE_67", [1290, 2796] => "APP_IPHONE_67", [1260, 2736] => "APP_IPHONE_67",
  [1206, 2622] => "APP_IPHONE_61", [1179, 2556] => "APP_IPHONE_61",
  [1284, 2778] => "APP_IPHONE_65", [1242, 2688] => "APP_IPHONE_65",
  [2880, 1800] => "APP_DESKTOP", [2560, 1600] => "APP_DESKTOP", [1440, 900] => "APP_DESKTOP", [1280, 800] => "APP_DESKTOP"
}.freeze
shots = ENV["SHOTS_DIR"].to_s
if !shots.empty? && Dir.exist?(shots)
  png_size = ->(path) { File.open(path, "rb") { |f| f.read(16); f.read(8).unpack("NN") } }
  Dir.children(shots).sort.each do |locale|
    files = Dir.glob(File.join(shots, locale, "*.png")).sort
    next if files.empty?
    loc = locs.find { |l| l.locale == locale }
    unless loc
      puts "no #{locale} localization: its screenshots are skipped"
      next
    end
    by_slot = files.group_by do |f|
      w, h = png_size.call(f)
      SLOTS[[w, h]] || SLOTS[[h, w]] || abort("a #{w}x#{h} image is not an App Store screenshot size")
    end
    sets = loc.get_app_screenshot_sets
    by_slot.each do |slot, list|
      abort "#{slot}: #{list.size} images, the App Store takes at most 10" if list.size > 10
      set = sets.find { |x| x.screenshot_display_type == slot } ||
            loc.create_app_screenshot_set(attributes: { screenshotDisplayType: slot })
      (set.app_screenshots || []).each(&:delete!)
      ids = list.map { |f| Spaceship::ConnectAPI::AppScreenshot.create(app_screenshot_set_id: set.id, path: f).id }
      set.reorder_screenshots(app_screenshot_ids: ids)
      puts "#{locale} #{slot}: #{ids.size} screenshots"
    end
    # a submission with screenshots still processing is refused: wait for them
    60.times do
      states = loc.get_app_screenshot_sets.flat_map do |x|
        (x.app_screenshots || []).map { |a| (a.asset_delivery_state || {})["state"].to_s }
      end
      abort "a screenshot failed Apple's processing" if states.include?("FAILED")
      break if states.all? { |st| st == "COMPLETE" }
      sleep 10
    end
  end
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
