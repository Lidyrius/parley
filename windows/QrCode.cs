namespace Parley;

// A QR code drawn in the setup window (step 8, "Handy koppeln") — macOS: CoreImage's
// CIQRCodeGenerator at correction level M. Byte mode, level M, the smallest version that fits,
// the mask with the lowest penalty. After Project Nayuki's QR Code generator (MIT licence),
// cut down to what the pairing link needs — no package for one picture.
public sealed class QrCode
{
    public int Size { get; }
    private readonly bool[,] _dark;       // [y, x]
    private readonly bool[,] _function;   // finder / timing / alignment / format / version modules

    public bool this[int x, int y] => _dark[y, x];

    // Level M, per version (index 0 unused): error correction codewords per block, and blocks.
    private static readonly int[] EccPerBlock =
        { -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 };
    private static readonly int[] Blocks =
        { -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 };
    private const int FormatLevelM = 0;   // the two format bits for level M

    // `text` as UTF-8; null when it is too long for any version. `mask` -1 = the best (tests force one).
    public static QrCode? Make(string text, int mask = -1) => Make(System.Text.Encoding.UTF8.GetBytes(text), mask);

    public static QrCode? Make(byte[] data, int mask = -1)
    {
        for (var version = 1; version <= 40; version++)
        {
            var capacity = DataCodewords(version) * 8;
            var used = 4 + (version <= 9 ? 8 : 16) + data.Length * 8;
            if (used <= capacity) return new QrCode(version, Codewords(data, version), mask);
        }
        return null;
    }

    private QrCode(int version, byte[] codewords, int mask)
    {
        Size = version * 4 + 17;
        _dark = new bool[Size, Size];
        _function = new bool[Size, Size];
        DrawFunctionPatterns(version);
        DrawCodewords(AddEccAndInterleave(codewords, version));
        if (mask < 0)
        {
            var best = int.MaxValue;
            for (var m = 0; m < 8; m++)
            {
                ApplyMask(m);
                DrawFormatBits(m);
                var penalty = Penalty();
                if (penalty < best) { best = penalty; mask = m; }
                ApplyMask(m);   // XOR again = undo
            }
        }
        ApplyMask(mask);
        DrawFormatBits(mask);
    }

    // ---- data -------------------------------------------------------------------------------

    private static int RawDataModules(int version)
    {
        var result = (16 * version + 128) * version + 64;
        if (version >= 2)
        {
            var align = version / 7 + 2;
            result -= (25 * align - 10) * align - 55;
            if (version >= 7) result -= 36;
        }
        return result;
    }

    private static int DataCodewords(int version) => RawDataModules(version) / 8 - EccPerBlock[version] * Blocks[version];

    // Mode (byte), count, the bytes, terminator, then 0xEC / 0x11 padding up to the capacity.
    private static byte[] Codewords(byte[] data, int version)
    {
        var bits = new List<bool>();
        void Append(int value, int length) { for (var i = length - 1; i >= 0; i--) bits.Add(((value >> i) & 1) != 0); }
        Append(0x4, 4);
        Append(data.Length, version <= 9 ? 8 : 16);
        foreach (var b in data) Append(b, 8);
        var capacity = DataCodewords(version) * 8;
        Append(0, Math.Min(4, capacity - bits.Count));
        Append(0, (8 - bits.Count % 8) % 8);
        for (var pad = 0xEC; bits.Count < capacity; pad ^= 0xEC ^ 0x11) Append(pad, 8);
        var result = new byte[bits.Count / 8];
        for (var i = 0; i < bits.Count; i++)
            if (bits[i]) result[i >> 3] |= (byte)(1 << (7 - (i & 7)));
        return result;
    }

    private static byte[] AddEccAndInterleave(byte[] data, int version)
    {
        var blocks = Blocks[version];
        var eccLen = EccPerBlock[version];
        var raw = RawDataModules(version) / 8;
        var shortBlocks = blocks - raw % blocks;
        var shortLen = raw / blocks;
        var divisor = RsDivisor(eccLen);
        var all = new List<byte[]>();
        for (int i = 0, k = 0; i < blocks; i++)
        {
            var datLen = shortLen - eccLen + (i < shortBlocks ? 0 : 1);
            var dat = data.Skip(k).Take(datLen).ToArray();
            k += datLen;
            var ecc = RsRemainder(dat, divisor);
            var block = new byte[shortLen + 1];
            Array.Copy(dat, block, dat.Length);
            // A short block keeps one unused slot before its ECC, skipped when interleaving.
            Array.Copy(ecc, 0, block, shortLen + 1 - eccLen, eccLen);
            all.Add(block);
        }
        var result = new List<byte>(raw);
        for (var i = 0; i < shortLen + 1; i++)
            for (var j = 0; j < all.Count; j++)
                if (i != shortLen - eccLen || j >= shortBlocks) result.Add(all[j][i]);
        return result.ToArray();
    }

    private static byte[] RsDivisor(int degree)
    {
        var result = new byte[degree];
        result[degree - 1] = 1;
        var root = 1;
        for (var i = 0; i < degree; i++)
        {
            for (var j = 0; j < degree; j++)
            {
                result[j] = (byte)GfMultiply(result[j], root);
                if (j + 1 < degree) result[j] ^= result[j + 1];
            }
            root = GfMultiply(root, 0x02);
        }
        return result;
    }

    private static byte[] RsRemainder(byte[] data, byte[] divisor)
    {
        var result = new byte[divisor.Length];
        foreach (var b in data)
        {
            var factor = b ^ result[0];
            Array.Copy(result, 1, result, 0, result.Length - 1);
            result[^1] = 0;
            for (var i = 0; i < result.Length; i++) result[i] ^= (byte)GfMultiply(divisor[i], factor);
        }
        return result;
    }

    // GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
    private static int GfMultiply(int x, int y)
    {
        var z = 0;
        for (var i = 7; i >= 0; i--)
        {
            z = (z << 1) ^ ((z >> 7) * 0x11D);
            z ^= ((y >> i) & 1) * x;
        }
        return z;
    }

    // ---- the picture ------------------------------------------------------------------------

    private void SetFunction(int x, int y, bool dark)
    {
        _dark[y, x] = dark;
        _function[y, x] = true;
    }

    private void DrawFunctionPatterns(int version)
    {
        for (var i = 0; i < Size; i++)
        {
            SetFunction(6, i, i % 2 == 0);
            SetFunction(i, 6, i % 2 == 0);
        }
        DrawFinder(3, 3);
        DrawFinder(Size - 4, 3);
        DrawFinder(3, Size - 4);
        var align = AlignmentPositions(version);
        var n = align.Length;
        for (var i = 0; i < n; i++)
            for (var j = 0; j < n; j++)
                if (!(i == 0 && j == 0 || i == 0 && j == n - 1 || i == n - 1 && j == 0))
                    DrawAlignment(align[i], align[j]);
        DrawFormatBits(0);   // reserved now, the real bits come with the mask
        DrawVersion(version);
    }

    private void DrawFinder(int x, int y)
    {
        for (var dy = -4; dy <= 4; dy++)
            for (var dx = -4; dx <= 4; dx++)
            {
                var dist = Math.Max(Math.Abs(dx), Math.Abs(dy));
                int xx = x + dx, yy = y + dy;
                if (xx >= 0 && xx < Size && yy >= 0 && yy < Size) SetFunction(xx, yy, dist != 2 && dist != 4);
            }
    }

    private void DrawAlignment(int x, int y)
    {
        for (var dy = -2; dy <= 2; dy++)
            for (var dx = -2; dx <= 2; dx++)
                SetFunction(x + dx, y + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
    }

    private int[] AlignmentPositions(int version)
    {
        if (version == 1) return Array.Empty<int>();
        var count = version / 7 + 2;
        var step = version == 32 ? 26 : (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2;
        var result = new int[count];
        result[0] = 6;
        for (int i = count - 1, pos = Size - 7; i >= 1; i--, pos -= step) result[i] = pos;
        return result;
    }

    private static bool Bit(int x, int i) => ((x >> i) & 1) != 0;

    private void DrawFormatBits(int mask)
    {
        var data = FormatLevelM << 3 | mask;
        var rem = data;
        for (var i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        var bits = (data << 10 | rem) ^ 0x5412;
        for (var i = 0; i <= 5; i++) SetFunction(8, i, Bit(bits, i));
        SetFunction(8, 7, Bit(bits, 6));
        SetFunction(8, 8, Bit(bits, 7));
        SetFunction(7, 8, Bit(bits, 8));
        for (var i = 9; i < 15; i++) SetFunction(14 - i, 8, Bit(bits, i));
        for (var i = 0; i < 8; i++) SetFunction(Size - 1 - i, 8, Bit(bits, i));
        for (var i = 8; i < 15; i++) SetFunction(8, Size - 15 + i, Bit(bits, i));
        SetFunction(8, Size - 8, true);   // the dark module
    }

    private void DrawVersion(int version)
    {
        if (version < 7) return;
        var rem = version;
        for (var i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        var bits = version << 12 | rem;
        for (var i = 0; i < 18; i++)
        {
            var bit = Bit(bits, i);
            int a = Size - 11 + i % 3, b = i / 3;
            SetFunction(a, b, bit);
            SetFunction(b, a, bit);
        }
    }

    // The zigzag: two columns at a time from the right, up and down, around the function modules.
    private void DrawCodewords(byte[] data)
    {
        var i = 0;
        for (var right = Size - 1; right >= 1; right -= 2)
        {
            if (right == 6) right = 5;
            for (var vert = 0; vert < Size; vert++)
                for (var j = 0; j < 2; j++)
                {
                    var x = right - j;
                    var upward = ((right + 1) & 2) == 0;
                    var y = upward ? Size - 1 - vert : vert;
                    if (!_function[y, x] && i < data.Length * 8)
                    {
                        _dark[y, x] = Bit(data[i >> 3], 7 - (i & 7));
                        i++;
                    }
                }
        }
    }

    private void ApplyMask(int mask)
    {
        for (var y = 0; y < Size; y++)
            for (var x = 0; x < Size; x++)
            {
                var invert = mask switch
                {
                    0 => (x + y) % 2 == 0,
                    1 => y % 2 == 0,
                    2 => x % 3 == 0,
                    3 => (x + y) % 3 == 0,
                    4 => (x / 3 + y / 2) % 2 == 0,
                    5 => x * y % 2 + x * y % 3 == 0,
                    6 => (x * y % 2 + x * y % 3) % 2 == 0,
                    _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
                };
                if (invert && !_function[y, x]) _dark[y, x] = !_dark[y, x];
            }
    }

    // ---- mask penalty (ISO 18004 rules N1–N4) -----------------------------------------------

    private int Penalty()
    {
        var result = 0;
        for (var pass = 0; pass < 2; pass++)   // rows, then columns
            for (var a = 0; a < Size; a++)
            {
                var runColor = false;
                var run = 0;
                var history = new int[7];
                for (var b = 0; b < Size; b++)
                {
                    var dark = pass == 0 ? _dark[a, b] : _dark[b, a];
                    if (dark == runColor)
                    {
                        run++;
                        if (run == 5) result += 3;
                        else if (run > 5) result++;
                    }
                    else
                    {
                        AddHistory(run, history);
                        if (!runColor) result += CountFinderLike(history) * 40;
                        runColor = dark;
                        run = 1;
                    }
                }
                result += TerminateAndCount(runColor, run, history) * 40;
            }
        for (var y = 0; y < Size - 1; y++)
            for (var x = 0; x < Size - 1; x++)
            {
                var c = _dark[y, x];
                if (c == _dark[y, x + 1] && c == _dark[y + 1, x] && c == _dark[y + 1, x + 1]) result += 3;
            }
        var darkCount = 0;
        foreach (var d in _dark) if (d) darkCount++;
        var total = Size * Size;
        var k = (Math.Abs(darkCount * 20 - total * 10) + total - 1) / total - 1;
        return result + k * 10;
    }

    private int CountFinderLike(int[] h)
    {
        var n = h[1];
        var core = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n;
        return (core && h[0] >= n * 4 && h[6] >= n ? 1 : 0) + (core && h[6] >= n * 4 && h[0] >= n ? 1 : 0);
    }

    private int TerminateAndCount(bool runColor, int run, int[] history)
    {
        if (runColor) { AddHistory(run, history); run = 0; }
        run += Size;   // the light border after the last run
        AddHistory(run, history);
        return CountFinderLike(history);
    }

    private void AddHistory(int run, int[] history)
    {
        if (history[0] == 0) run += Size;   // the light border before the first run
        Array.Copy(history, 0, history, 1, history.Length - 1);
        history[0] = run;
    }

    // One pixel per module, with a four-module quiet zone; scale it up with nearest neighbour.
    public Bitmap ToBitmap(int border = 4)
    {
        var side = Size + border * 2;
        var bmp = new Bitmap(side, side);
        for (var y = 0; y < side; y++)
            for (var x = 0; x < side; x++)
            {
                int mx = x - border, my = y - border;
                var dark = mx >= 0 && mx < Size && my >= 0 && my < Size && _dark[my, mx];
                bmp.SetPixel(x, y, dark ? Color.Black : Color.White);
            }
        return bmp;
    }
}
