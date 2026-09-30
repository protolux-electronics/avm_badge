defmodule Badge.QRTest do
  use ExUnit.Case, async: true

  alias Badge.QR
  alias Badge.QR.Geometry

  @qr_asset_checksums %{
    1 => "90920fb05c124a44dee1abbf87636feb0a33c7e6a80bcd36c8d00582aa3613c1",
    2 => "425451af400e56d8eb273afa123598530646d583c65694d5d994e8d6510ad9a4",
    3 => "3d617dbc8c355bf7074afb201dd87f09bed91c4211a7b0a031aae4dc2bbdb0e3",
    4 => "f834c6fb6ec729a87cbb8a632fb9456075e444a35d799c94e4db6cc6d9c2c152",
    5 => "240b4a7b9d7927e2ef46bdba51d8ee26fe5ab8d279cdadc65ed7cfb066f8855a",
    6 => "857c9ef82a844ce868b163568d1711a04c9ad0c352e80ab1b17007cc471f61ca",
    7 => "d628b3ae3bd48f4bc2b097df7da73070820645089189f1a063d51d8f87c74773",
    8 => "6318c95ce70ef9b89877d46a1534129af200a4f314d977ea9026beb417d47ad3",
    9 => "0328774de53a01893759f6c4e55eb0969afe1f9a080d104a7fbb1ec7ceb109bd",
    10 => "ebe31cbda3aef88dfca57bb2f0d69a1361831ac33335b1fc1ec55181ea21b38b"
  }

  @hello """
  111111100101101111111
  100000100111001000001
  101110101101101011101
  101110100101001011101
  101110100010101011101
  100000100000101000001
  111111101010101111111
  000000001101100000000
  111011111111011000100
  000100001000001000010
  101000100010100011111
  110010001010001000010
  101001100110101010100
  000000001101010100110
  111111101001011100111
  100000101111110110000
  101110101001011100111
  101110100010001100110
  101110101110100010101
  100000101100001010010
  111111101100101100111
  """

  @repository """
  11111110001001110001001111111
  10000010010001010111101000001
  10111010100100010011001011101
  10111010010000100010001011101
  10111010010010110111001011101
  10000010001110011011001000001
  11111110101010101010101111111
  00000000100111101110000000000
  11101111100011011100011000100
  00000001010011101000101001001
  00100010101001101000111010111
  10000100111011100101000110010
  10111010101011100100011001011
  01110001111010001110111001001
  01100111001011001000001011011
  10000100101111111110111001010
  01111010110011000101101101011
  00111101000011001010011001101
  10111010000000100010010110011
  01110101010101100101111111010
  10001010010011001111111110000
  00000000100011101001100010111
  11111110110011000001101011011
  10000010111001011110100011000
  10111010101011001100111110001
  10111010011010001100100110101
  10111010100000001001000111001
  10000010110011111111110010010
  11111110100100011101110110011
  """

  @max_hash Base.decode16!("AB5D4C958687EB5ECC9CB8B2319824B06D79594E8B99B11530309263C67EE37A")

  defp bits(rows) do
    rows
    |> String.replace("\n", "")
    |> :binary.bin_to_list()
    |> Enum.map(fn
      ?0 -> 0
      ?1 -> 1
    end)
    |> :binary.list_to_bin()
  end

  test "matches a version-one byte-mode reference" do
    assert {:ok, %{version: 1, size: 21, modules: modules}} = QR.encode("HELLO")
    assert modules == bits(@hello)
  end

  test "matches the repository's version-three reference including alignment" do
    url = "https://github.com/protolux-electronics/avm_badge"

    assert {:ok, %{version: 3, size: 29, modules: modules}} = QR.encode(url)
    assert modules == bits(@repository)
  end

  test "chooses the smallest supported version at each byte-mode boundary" do
    for {length, version} <- [
          {17, 1},
          {18, 2},
          {32, 2},
          {33, 3},
          {53, 3},
          {54, 4},
          {78, 4},
          {79, 5},
          {106, 5},
          {107, 6},
          {134, 6},
          {135, 7},
          {154, 7},
          {155, 8},
          {192, 8},
          {193, 9},
          {230, 9},
          {231, 10},
          {271, 10}
        ] do
      assert {:ok, %{version: ^version}} = QR.encode(:binary.copy("a", length))
    end
  end

  test "encodes 255 bytes with version ten's two-byte count and mixed block lengths" do
    assert {:ok, %{version: 10, size: 57, modules: modules}} =
             QR.encode(:binary.copy("a", 255))

    assert :crypto.hash(:sha256, modules) == @max_hash
  end

  test "rejects payloads beyond version ten" do
    assert QR.encode(:binary.copy("a", 272)) == {:error, :too_long}
  end

  test "has generated geometry for every supported version" do
    assert Geometry.versions() == :lists.seq(1, 10)

    for version <- Geometry.versions() do
      %{size: size, template: template} = Geometry.for_version(version)
      assert size == 17 + 4 * version
      assert byte_size(template) == size * size * 2
    end

    assert Geometry.for_version(11) == nil
  end

  test "bakes the fixed mask into the geometry" do
    assert Geometry.mask() in 0..7
    assert Geometry.fixed_light() == 0xFFFE
    assert Geometry.fixed_dark() == 0xFFFF
    assert Geometry.data_position() == 0xFFF
  end

  test "builds one black-on-white image with a four-module quiet zone" do
    {:ok, code} = QR.encode("HELLO")

    assert {:scaled_cropped_image, 10, 20, 116, 116, 0xFFFFFF, 0, 0, 4, 4, [],
            {:rgba8888, 29, 29, pixels}} = QR.item(code, 10, 20, 4)

    assert byte_size(pixels) == 29 * 29 * 4

    assert :binary.part(pixels, 0, 29 * 4 * 4) ==
             :binary.copy(<<255, 255, 255, 255>>, 29 * 4)

    assert :binary.part(pixels, (4 * 29 + 4) * 4, 4) == <<0, 0, 0, 255>>
  end

  test "width/1 matches the image encode/1 draws, without reading assets" do
    for length <- [0, 17, 18, 53, 54, 271] do
      {:ok, %{image: {:rgba8888, width, width, _pixels}}} = QR.encode(:binary.copy("a", length))
      assert QR.width(length) == width
    end

    assert QR.width(272) == nil
  end

  test "the asset files hold the exact bytes the geometry once compiled in" do
    for version <- Geometry.versions() do
      %{template: template} = Geometry.for_version(version)

      assert :crypto.hash(:sha256, template) |> Base.encode16(case: :lower) ==
               Map.fetch!(@qr_asset_checksums, version)
    end
  end

  describe "Geometry.template/2" do
    test "a partition without the template answers undefined, which is nil rather than a crash" do
      assert Geometry.template(:undefined, 1) == nil
    end

    test "anything that is not the bytes is no template either" do
      assert Geometry.template(:some_other_atom, 1) == nil
    end

    test "wraps real bytes with the version's size" do
      %{template: bytes} = Geometry.for_version(3)

      assert Geometry.template(bytes, 3) == %{size: 29, template: bytes}
    end
  end

  describe "result/3" do
    test "a missing template yields :no_assets rather than a crash" do
      assert QR.result("HELLO", %{version: 1}, nil) == {:error, :no_assets}
    end
  end
end
