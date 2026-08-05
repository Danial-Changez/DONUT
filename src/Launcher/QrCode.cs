#nullable enable

using QRCoder;

namespace Donut.Qr
{
    /// <summary>
    /// Thin wrapper over bundled QRCoder: encodes text to a PNG entirely in memory via the
    /// dependency-free <see cref="PngByteQRCode"/> path (no System.Drawing/GDI). Kept in C#
    /// so the QR call sidesteps PowerShell's handling of QRCoder's optional parameters.
    /// </summary>
    /// <remarks>
    /// Compiled into Donut.Launcher for production. Start-Donut.ps1 also compiles it from
    /// this source, guarded, so the `pwsh -Sta` dev path resolves the type.
    /// </remarks>
    public static class QrCode
    {
        /// <summary>
        /// Encodes <paramref name="text"/> to a QR-code PNG in the given module colours
        /// (RGBA, so a transparent background is supported). ECC level Q (~25% recovery)
        /// keeps the code scannable under mild on-screen glare. DONUT renders it inverted,
        /// light modules on the dark card, which is field-gated on the hardware scanner
        /// decoding inverse QR. Revert to dark-on-light if it cannot.
        /// </summary>
        /// <param name="text">The payload to encode (e.g. a BitLocker recovery key).</param>
        /// <param name="pixelsPerModule">Size of each QR module in pixels.</param>
        /// <param name="darkRgba">Dark-module colour as [R,G,B,A].</param>
        /// <param name="lightRgba">Light-module/background colour as [R,G,B,A].</param>
        /// <returns>PNG bytes, never written to disk by this method.</returns>
        public static byte[] EncodePng(string text, int pixelsPerModule, byte[] darkRgba, byte[] lightRgba)
        {
            var generator = new QRCodeGenerator();
            var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.Q);
            return new PngByteQRCode(data).GetGraphic(pixelsPerModule, darkRgba, lightRgba);
        }
    }
}
