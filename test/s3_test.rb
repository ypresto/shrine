require "test_helper"

require "shrine/storage/s3"
require "shrine/storage/file_system"
require "shrine/storage/linter"

require "down"
require "securerandom"
require "cgi"

require "dotenv"
Dotenv.load!

describe Shrine::Storage::S3 do
  def s3(**options)
    options[:bucket]            ||= ENV.fetch("S3_BUCKET")
    options[:region]            ||= ENV.fetch("S3_REGION")
    options[:access_key_id]     ||= ENV.fetch("S3_ACCESS_KEY_ID")
    options[:secret_access_key] ||= ENV.fetch("S3_SECRET_ACCESS_KEY")

    Shrine::Storage::S3.new(**options)
  end

  def filesystem
    Shrine::Storage::FileSystem.new(Dir.tmpdir)
  end

  before do
    @s3 = s3
    shrine = Class.new(Shrine)
    shrine.storages = {s3: @s3}
    @uploader = shrine.new(:s3)
  end

  after do
    @s3.clear!
  end

  it "passes the linter" do
    Shrine::Storage::Linter.new(s3).call
  end

  it "passes the linter with prefix" do
    Shrine::Storage::Linter.new(s3(prefix: "foo")).call
  end

  describe "#upload" do
    it "uploads files" do
      @s3.upload(image, "foo")
      assert image.read, @s3.download("foo").read
    end

    it "uploads filesystem uploaded files" do
      shrine = Class.new(Shrine)
      shrine.storages = {filesystem: filesystem}
      uploader = shrine.new(:filesystem)

      uploaded_file = uploader.upload(fakeio("file"))
      @s3.upload(uploaded_file, "foo")
      assert "file", @s3.download("foo").read
    end

    it "uploads IO objects" do
      @s3.upload(fakeio("file"), "foo")
      assert "file", @s3.download("foo").read
    end

    it "copies the file if it's from also S3" do
      uploaded_file = @uploader.upload(fakeio, location: "foo")
      assert @s3.send(:copyable?, uploaded_file)
      @s3.upload(uploaded_file, "bar")
      assert @s3.exists?("bar")
    end

    it "preserves the content type" do
      uploaded_file = @uploader.upload(fakeio(content_type: "foo/bar"), location: "foo")
      tempfile = Down.download(@s3.url("foo"))
      assert_equal "foo/bar", tempfile.content_type

      @uploader.upload(uploaded_file, location: "bar")
      tempfile = Down.download(@s3.url("bar"))
      assert_equal "foo/bar", tempfile.content_type
    end

    it "preserves the filename" do
      uploaded_file = @uploader.upload(fakeio(filename: "file.txt"), location: "foo")
      tempfile = Down.download(@s3.url("foo"))
      assert_equal "file.txt", tempfile.original_filename

      @uploader.upload(uploaded_file, location: "bar")
      tempfile = Down.download(@s3.url("bar"))
      assert_equal "file.txt", tempfile.original_filename
    end

    it "handles non-ASCII characters, quotes and spaces in Content-Disposition" do
      @s3.upload(fakeio, "foo", content_disposition: 'inline; filename=""été bar.pdf""')
      tempfile = Down.download(@s3.url("foo"))
      assert_equal '"été bar.pdf"', CGI.unescape(tempfile.original_filename)
    end

    it "applies upload options" do
      @s3 = s3(upload_options: {content_type: "foo/bar"})
      @s3.upload(fakeio, "foo")
      tempfile = Down.download(@s3.url("foo"))
      assert_equal "foo/bar", tempfile.content_type
    end

    it "accepts additional upload options via metadata" do
      @s3.upload(fakeio, "foo", content_type: "foo/bar")
      tempfile = Down.download(@s3.url("foo"))
      assert_equal "foo/bar", tempfile.content_type
    end

    it "doesn't require S3 files to have a size" do
      uploaded_file = @uploader.upload(fakeio)
      uploaded_file.metadata.delete("size")
      @s3.upload(uploaded_file, "foo.jpg")
      assert @s3.exists?("foo.jpg")
    end
  end

  describe "#url" do
    it "provides a download URL for the file" do
      @s3.upload(fakeio("image"), "foo")
      downloaded = Down.download(@s3.url("foo"))
      assert_equal "image", downloaded.read
    end

    it "can provide a force download URL" do
      url = @s3.url("foo", download: true)
      assert_match "response-content-disposition=attachment", url
    end

    it "can provide a CDN url" do
      url = s3.url("foo/bar quux", host: "http://123.cloudfront.net")
      assert_match "http://123.cloudfront.net/foo/bar%20quux", url

      url = s3.url("foo/bar quux", host: "http://123.cloudfront.net", public: true)
      assert_equal "http://123.cloudfront.net/foo/bar%20quux", url

      url = s3(force_path_style: true).url("foo/bar quux", host: "http://123.cloudfront.net")
      assert_match "http://123.cloudfront.net/foo/bar%20quux", url

      url = s3(force_path_style: true).url("foo/bar quux", host: "http://123.cloudfront.net", public: true)
      assert_equal "http://123.cloudfront.net/foo/bar%20quux", url

      url = s3.url(@s3.bucket.name, host: "http://123.cloudfront.net", public: true)
      assert_equal "http://123.cloudfront.net/#{@s3.bucket.name}", url
    end

    it "can provide a public url" do
      url = @s3.url("foo", public: true)
      assert_match %r{https://#{@s3.bucket.name}\.s3.*\.amazonaws\.com/foo}, url
    end
  end

  describe "#presign" do
    it "returns a PresignedPost for the given id" do
      presign = @s3.presign("foo")
      refute_empty presign.url
      assert_equal "foo", presign.fields["key"]
    end

    it "accepts additional options" do
      presign = @s3.presign("foo", content_type: "image/jpeg")
      assert_equal "image/jpeg", presign.fields["Content-Type"]
    end

    it "applies upload options" do
      @s3 = s3(upload_options: {content_type: "image/jpeg"})
      presign = @s3.presign("foo")
      assert_equal "image/jpeg", presign.fields["Content-Type"]
    end

    it "gives higher precedence to options directly passed in" do
      @s3 = s3(upload_options: {content_type: "image/jpeg"})
      presign = @s3.presign("foo", content_type: "")
      assert_equal "", presign.fields["Content-Type"]
    end

    it "works with the :endpoint option" do
      s3 = s3(endpoint: "http://foo.com")
      presign = s3.presign("foo")
      assert_equal "http://#{s3.bucket.name}.foo.com", presign.url
    end
  end

  describe "#object" do
    it "returns an Aws::S3::Object" do
      object = @s3.object("foo")
      assert_equal "foo", object.key
      assert_equal @s3.bucket.name, object.bucket.name
    end

    it "applies the :prefix" do
      object = s3(prefix: "foo").object("bar")
      assert_equal "foo/bar", object.key
    end
  end

  describe "#client" do
    it "returns an Aws::S3::Client with credentials" do
      assert_instance_of Aws::S3::Client, @s3.client
      assert_equal ENV.fetch("S3_ACCESS_KEY_ID"),     @s3.client.config.access_key_id
      assert_equal ENV.fetch("S3_SECRET_ACCESS_KEY"), @s3.client.config.secret_access_key
      assert_equal ENV.fetch("S3_REGION"),            @s3.client.config.region
    end
  end

  describe "#bucket" do
    it "returns an Aws::S3::Bucket" do
      assert_instance_of Aws::S3::Bucket, @s3.bucket
      assert_equal ENV.fetch("S3_BUCKET"), @s3.bucket.name
    end
  end

  describe "#prefix" do
    it "returns the given :prefix" do
      assert_equal "foo", s3(prefix: "foo").prefix
    end
  end

  describe "#s3" do
    it "returns the deprecated Aws::S3::Resource object" do
      resource = @s3.s3
      assert_instance_of Aws::S3::Resource, resource
      assert_equal resource.client, @s3.client
    end
  end
end
