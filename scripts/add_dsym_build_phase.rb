#!/usr/bin/env ruby
# One-shot tool: adds a Run Script Build Phase to the Runner target so every
# archive auto-generates dSYMs for vendored binary frameworks (media_kit /
# mpv / ffmpeg / etc.) that don't ship them. Run once after cloning, or any
# time the build phase gets stripped by Xcode.
#
#   ruby scripts/add_dsym_build_phase.rb
#
# Idempotent — re-running won't duplicate the phase.

require 'xcodeproj'

PROJECT = File.expand_path('../ios/Runner.xcodeproj', __dir__)
PHASE_NAME = '[radio-crestin] Generate dSYMs for vendored frameworks'

SCRIPT = <<~SH
  # Vendored binary frameworks (media_kit_libs_ios_video → mpv / ffmpeg /
  # ass / freetype / harfbuzz / mbedtls / png16 / uchardet / xml2 / dav1d /
  # fribidi / swresample / swscale) ship as precompiled .framework bundles
  # without dSYMs. App Store Connect emits "Upload Symbols Failed" warnings
  # for each on every TestFlight upload. dsymutil produces a stub dSYM with
  # the matching UUID, which silences the warnings (the binaries have no
  # debug info to recover, so no symbolication is gained either way).
  set -eu
  [ -z "${DWARF_DSYM_FOLDER_PATH:-}" ] && exit 0
  [ -z "${TARGET_BUILD_DIR:-}" ] && exit 0
  APP_FW_DIR="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Frameworks"
  [ -d "$APP_FW_DIR" ] || exit 0
  mkdir -p "$DWARF_DSYM_FOLDER_PATH"
  for fw_path in "$APP_FW_DIR"/*.framework; do
    [ -d "$fw_path" ] || continue
    fw=$(basename "$fw_path" .framework)
    bin="$fw_path/$fw"
    out="$DWARF_DSYM_FOLDER_PATH/${fw}.framework.dSYM"
    [ -d "$out" ] && continue
    [ -f "$bin" ] || continue
    /usr/bin/dsymutil "$bin" -o "$out" 2>/dev/null || true
  done
SH

project = Xcodeproj::Project.open(PROJECT)
runner = project.targets.find { |t| t.name == 'Runner' } or abort('Runner target not found')

if runner.shell_script_build_phases.any? { |p| p.name == PHASE_NAME }
  puts "phase already present, nothing to do"
  exit 0
end

phase = runner.new_shell_script_build_phase(PHASE_NAME)
phase.shell_script = SCRIPT
phase.shell_path = '/bin/sh'
phase.run_only_for_deployment_postprocessing = '0'
phase.always_out_of_date = '1'

project.save
puts "added '#{PHASE_NAME}' to Runner target"
