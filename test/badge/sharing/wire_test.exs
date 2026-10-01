defmodule Badge.Sharing.WireTest do
  use ExUnit.Case, async: true

  alias Badge.Ir
  alias Badge.Profile
  alias Badge.Sharing.Wire

  describe "fields and tags" do
    test "every profile field but the QR choice has a tag, in profile order" do
      assert Wire.fields() == Profile.keys() -- [:qr]
    end

    test "tags are one byte below the printable range, and round-trip" do
      for key <- Wire.fields() do
        tag = Wire.tag(key)

        assert tag in 1..0x1F
        assert Wire.key(tag) == key
      end
    end

    test "a field no frame carries has no tag, and a stray byte no field" do
      assert Wire.tag(:qr) == nil
      assert Wire.key(0) == nil
      assert Wire.key(0x7F) == nil
    end
  end

  describe "encode/3 and decode/1" do
    test "a frame round-trips its field, share set and value" do
      payload = Wire.encode(:company, [:name, :company, :links], "Goatmire International")

      assert Wire.decode(payload) ==
               {:ok, :company, [:name, :company, :links], "Goatmire International"}
    end

    test "every field at capacity fits a frame" do
      for key <- Wire.fields() do
        value = :binary.copy("x", Profile.capacity(key))
        payload = Wire.encode(key, Wire.fields(), value)

        assert is_binary(payload)
        assert byte_size(payload) <= Ir.max_payload()
        assert Wire.decode(payload) == {:ok, key, Wire.fields(), value}
      end
    end

    test "the header is two bytes: the tag and the mask" do
      assert Wire.encode(:name, [:name], "Gus") == <<1, 1, "Gus">>
      assert Wire.encode(:github, [:name, :github], "gus") == <<4, 0b1001, "gus">>
    end

    test "an empty value is a frame too" do
      assert Wire.decode(Wire.encode(:email, [:name, :email], "")) ==
               {:ok, :email, [:name, :email], ""}
    end

    test "a value the link could not carry is refused rather than cut" do
      long = :binary.copy("x", Ir.max_payload() - 1)

      assert Wire.encode(:links, [:name, :links], long) == {:error, :too_long}
    end

    test "a field no frame carries is refused" do
      assert Wire.encode(:qr, [:name], "github") == {:error, :unknown}
    end

    test "a printable first byte is a bare name from older firmware" do
      assert Wire.decode("Pat") == {:ok, :name, [:name], "Pat"}
      assert Wire.decode("P") == {:ok, :name, [:name], "P"}
      assert Wire.decode(" spaced") == {:ok, :name, [:name], " spaced"}
    end

    test "bytes 0x10 to 0x1F are other pages' traffic" do
      assert Wire.decode(<<0x10, 0, 1, 0, 0, 0, 1>>) == :other
      assert Wire.decode(<<0x1F>>) == :other
      assert Wire.decode(<<0x0F, 1, "x">>) == :error
    end

    test "no field takes a byte left to other pages" do
      for key <- Wire.fields(), do: assert(Wire.tag(key) < 0x10)
    end

    test "a tag naming no field is an error" do
      assert Wire.decode(<<0, 1, "x">>) == :error
      assert Wire.decode(<<9, 1, "x">>) == :error
    end

    test "too short to hold a header is an error" do
      assert Wire.decode(<<>>) == :error
      assert Wire.decode(<<1>>) == :error
    end
  end

  describe "mask/1 and keys/1" do
    test "name is bit zero" do
      assert Wire.mask([:name]) == 1
      assert Wire.keys(1) == [:name]
    end

    test "any set of fields round-trips in tag order" do
      assert Wire.keys(Wire.mask([:links, :name, :email])) == [:name, :email, :links]
    end

    test "unknown keys and stray bits are ignored" do
      assert Wire.mask([:name, :qr, :nonesuch]) == 1
      assert Wire.keys(0xFF00 + 1) == [:name]
    end
  end
end
