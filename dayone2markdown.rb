#!/usr/bin/env ruby
# frozen_string_literal: true

require "set"
require "fileutils"
require "json"
require "uri"
require "tmpdir"

def print_usage(code, additional = nil)
  puts additional if additional
  $stdout.puts <<~USAGE
    #{$0} <dayone json zip> <output_dir>

    dayone exported data dir should have following structure:
    1. 1~N <dairy>.json
    2. photos dir to save image ref
  USAGE
  exit code
end

def main(argv)
  print_usage(0) if %w[-h --help].any? { |w| argv.include? w }
  print_usage(0) if argv.size < 2

  with_input_dir(File.expand_path(argv[0])) do |unzip_dir|
    Dayone2Markdown.new(unzip_dir, File.expand_path(argv[1])).run!
  end
end

def with_input_dir(path)
  return yield path if Dir.exist?(path)

  tmpdir = Dir.tmpdir
  unzip_dir = File.join tmpdir, "#{File.basename path, '.*'}-day1-unzip"
  FileUtils.rm_rf(unzip_dir) if File.exist? unzip_dir

  begin
    system("unzip", path, "-d", unzip_dir) or raise "unzip failed for #{path}"
    yield unzip_dir
  ensure
    FileUtils.rm_rf(unzip_dir)
  end
end

class Dayone2Markdown
  def initialize(input, output)
    @input = input
    @output = output
  end

  def run!
    ensure_image
    extract_dairy
  end

  def ensure_image
    return if @input == @output
    FileUtils.mkdir_p @output
    image_ref_dir = File.join @input, 'photos/'
    if Dir.exist? image_ref_dir
      output_dir = File.join(@output, "photos/")
      system("rsync", "-a", image_ref_dir, output_dir) or raise "rsync photos failed"

      @photos = Dir.glob("*", base: output_dir).to_h do |path|
        next File.basename(path, ".*"), path
      end
    end
  end

  def extract_dairy
    Dir.glob(File.join(@input, "*.json")) do |path|
      basename = URI.decode_www_form_component File.basename(path, ".json")
      dir = File.join(@output, basename)
      FileUtils.mkdir_p(dir)

      entries = JSON.parse(File.read(path)).fetch "entries"
      entries.each do |entry|
        extract_one_entry entry, dir
      end
    end
  end

  # @param entry [Hash]
  def extract_one_entry(entry, output_dir)
    entry = entry.dup
    id = entry.delete("uuid")

    text = entry.delete("text")
    entry.delete("richText")
    photos = entry["photos"]
    photo_path = lambda do |uuid|
      unless photos.is_a? Hash
        photos = photos.to_h do |photo|
          next photo["identifier"], photo
        end
      end

      path = @photos and
        md5 = photos.dig(uuid, "md5") and
        @photos[md5]

      "../photos/#{path or uuid}"
    end

    text = text.gsub(%r{\(dayone-moment://(\S*)\)}) { "(#{photo_path.($1)})" }

    metadata = []
    if tags = entry.delete("tags") and !tags.empty?
      metadata.push tags.map { |v| "##{v}" }.join("  ")
    end
    entry.each do |key, value|
      v = format_meta_value(value) or next
      metadata.push("#{key}: #{v}")
    end

    File.open(File.join(output_dir, "#{id}.md"), "w") do |f|
      f.write(metadata.map { |v| "> #{v}  \n" }.join(""))
      f.write("\n")
      f.write(text)
    end
    puts "extracted #{id} to #{output_dir}"
  end

  def format_meta_value(value)
    case value
    when false, 0, "", [], {}, nil
      return nil
    when Hash, Array
      return value.to_json.gsub("\n", "\\n")
    else
      return value
    end
  end
end

main ARGV
