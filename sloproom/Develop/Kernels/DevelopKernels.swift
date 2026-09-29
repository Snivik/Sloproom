//
//  DevelopKernels.swift
//  sloproom
//
//  Custom Core Image color kernels for the develop stages, written in Metal and compiled at
//  runtime with `CIKernel.kernels(withMetalString:)` (no -fcikernel build flags needed; requires a
//  Metal-backed CIContext, which RenderPipeline always uses on Apple Silicon).
//
//  Conventions (see docs/ARCHITECTURE.md "Color spaces per stage"):
//  - Inputs are the pipeline working space: LINEAR, extended-range sRGB primaries.
//  - "P" = perceptual luminance = Y^(1/2.2) (Y = Rec.709 luminance, sign-preserving). Tone and
//    detail operations work on P and are applied back to RGB as a luminance ratio (keeps hue).
//  - Color operations (vibrance, saturation, color mixer) work in Oklab / OkLCh.
//

import Foundation
import CoreImage

nonisolated enum DevelopKernels {
    /// Perceptual luminance P in RGB (alpha 1). Guide/base image for local operations.
    static let perceptualLuma = kernel("dk_perceptualLuma")
    /// min(r, g, b) in RGB — dark channel for dehaze.
    static let darkChannel = kernel("dk_darkChannel")
    /// Guided filter: (guide I, value p) -> (I, I², p, I·p).
    static let guidedPack = kernel("dk_gfPack")
    /// Guided filter: (blurred pack, eps) -> (a, b, 0, 1).
    static let guidedCoefficients = kernel("dk_gfAB")
    /// Guided filter: (guide I, upsampled (a, b)) -> q = a·I + b in RGB.
    static let guidedApply = kernel("dk_gfApply")
    /// (image, base, a = contrast/highlights/shadows/whites, b = blacks/useBase/-/-), all -1...1.
    static let tone = kernel("dk_tone")
    /// (image, texFine, texCoarse, clarityBase, p = texture/clarity/-/-).
    static let detail = kernel("dk_detail")
    /// (image, darkBase, amount -1...1).
    static let dehaze = kernel("dk_dehaze")
    /// (image, p = vibrance/saturation/-/-).
    static let vibranceSaturation = kernel("dk_vibSat")
    /// (image, hue0, hue1, sat0, sat1, lum0, lum1): 8 bands as two float4 each, -1...1.
    static let colorMixer = kernel("dk_colorMixer")
    /// (image, rect = x/y/w/h of the final extent, p = amount/midpoint/roundness/feather).
    static let vignette = kernel("dk_vignette")
    /// (image, noise (r channel, mean 0.5), amount).
    static let grain = kernel("dk_grain")

    /// Each kernel is compiled from its OWN Metal source (shared helpers + one function):
    /// Core Image resolves every kernel of a multi-function Metal string to the same function.
    private static func kernel(_ name: String) -> CIColorKernel? {
        guard let body = kernelSources[name] else { return nil }
        let source = prelude + "extern \"C\" { namespace coreimage {\n" + body + "\n}}\n"
        do {
            let kernels = try CIKernel.kernels(withMetalString: source)
            if let k = kernels.first(where: { $0.name == name }) as? CIColorKernel { return k }
            print("DevelopKernels: \(name) not found in compiled source")
        } catch {
            print("DevelopKernels: failed to compile \(name): \(error)")
        }
        return nil
    }

    /// Compiles all kernels (call once off the main thread, e.g. when Develop opens).
    static func warmUp() {
        _ = [perceptualLuma, darkChannel, guidedPack, guidedCoefficients, guidedApply, tone, detail, dehaze, vibranceSaturation, colorMixer, vignette, grain]
    }

    /// Runs a kernel over `image`'s extent; returns `image` unchanged if the kernel is unavailable.
    static func apply(_ kernel: CIColorKernel?, _ image: CIImage, _ args: [Any]) -> CIImage {
        guard let kernel else { return image }
        return kernel.apply(extent: image.extent, arguments: [image] + args) ?? image
    }

    static func vector(_ a: Double, _ b: Double = 0, _ c: Double = 0, _ d: Double = 0) -> CIVector {
        CIVector(x: CGFloat(a), y: CGFloat(b), z: CGFloat(c), w: CGFloat(d))
    }

    // MARK: - Metal source

    private static let prelude = #"""
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    namespace dk {
        constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);
        inline float luma(float3 c) { return dot(c, kLuma); }
        inline float toP(float y) { return sign(y) * pow(abs(y), 1.0 / 2.2); }
        inline float fromP(float p) { return sign(p) * pow(abs(p), 2.2); }

        /// Scales rgb so its luminance becomes yNew (keeps chromaticity); near-black adds gray.
        inline float3 withLuma(float3 c, float y, float yNew) {
            if (y > 1e-5) { return c * (yNew / y); }
            return c + (yNew - y);
        }

        /// Applies a new perceptual luminance p2 (was p). Darkening scales rgb (keeps hue and
        /// saturation); lifting near-black pixels adds neutral light instead, so their unreliable
        /// chroma (noise, flare) isn't amplified into colored blotches.
        inline float3 withP(float3 c, float y, float p, float p2) {
            float y2 = fromP(max(p2, 0.0));
            float3 ratio = withLuma(c, y, y2);
            if (p2 <= p) { return ratio; }
            float m = 1.0 - smoothstep(0.03, 0.22, p);
            return mix(ratio, c + (y2 - y), m);
        }

        inline float cbrtS(float x) { return sign(x) * pow(abs(x), 1.0 / 3.0); }

        inline float3 toOklab(float3 c) {
            float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
            float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
            float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
            l = cbrtS(l); m = cbrtS(m); s = cbrtS(s);
            return float3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                          1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                          0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
        }

        inline float3 fromOklab(float3 lab) {
            float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
            float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
            float s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
            l = l * l * l; m = m * m * m; s = s * s * s;
            return float3( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                          -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                          -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
        }

        /// Contrast in P around a mid-gray pivot. c in -1...1. Keeps 0 and 1 fixed for c > 0.
        inline float contrastCurve(float x, float c) {
            const float pv = 0.46;
            if (c == 0.0) { return x; }
            if (c < 0.0) { return mix(x, pv + (x - pv) * 0.55, -c); }
            if (x <= 0.0 || x >= 1.0) { return x; }
            float g = 1.0 + 0.9 * c;
            return x < pv ? pv * pow(x / pv, g) : 1.0 - (1.0 - pv) * pow((1.0 - x) / (1.0 - pv), g);
        }

        /// Highlights / shadows / whites / blacks / contrast on perceptual luminance.
        /// b = local (smoothed) P used for the highlight/shadow masks.
        inline float toneP(float p, float b, float4 a, float blacks) {
            float x = contrastCurve(p, a.x);
            // Shadows / highlights: gains driven by the smooth base, so local detail is kept.
            float ws = 1.0 - smoothstep(0.02, 0.55, b);
            // Peaks in the bright tones; eases off on clipped white (that's the Whites slider's job).
            float wh = smoothstep(0.45, 0.95, b) * (1.0 - 0.35 * smoothstep(0.98, 1.25, b));
            float sg = a.z > 0.0 ? 1.1 * a.z : 0.5 * a.z;
            float hg = a.y > 0.0 ? 0.35 * a.y : 0.5 * a.y;
            x *= (1.0 + sg * ws) * (1.0 + hg * wh);
            // Whites: scale the top of the curve.
            x *= 1.0 + 0.35 * a.w * smoothstep(0.25, 1.0, x);
            // Blacks: move the black point, fading out towards the midtones.
            float bp = -0.07 * blacks;
            float moved = (x - bp) / (1.0 - bp);
            x = mix(moved, x, smoothstep(0.0, 0.55, x));
            return x;
        }

        /// Smooth partition of unity over the 8 color-mixer bands (OkLCh hue, degrees).
        constant float kBandHue[8] = { 29.2, 55.0, 105.0, 142.5, 194.8, 264.1, 293.8, 328.4 };

        inline void bandWeights(float h, thread int &i0, thread int &i1, thread float &t) {
            i0 = 7; i1 = 0;
            for (int i = 0; i < 8; i++) {
                int j = (i + 1) % 8;
                float c0 = kBandHue[i], c1 = kBandHue[j] + (j == 0 ? 360.0 : 0.0);
                float hh = (j == 0 && h < c0) ? h + 360.0 : h;
                if (hh >= c0 && hh < c1) { i0 = i; i1 = j; t = (hh - c0) / (c1 - c0); t = t * t * (3.0 - 2.0 * t); return; }
            }
            t = 0.0;
        }

        inline float gapNext(int i) { float d = kBandHue[(i + 1) % 8] - kBandHue[i]; return d < 0.0 ? d + 360.0 : d; }
        inline float gapPrev(int i) { float d = kBandHue[i] - kBandHue[(i + 7) % 8]; return d < 0.0 ? d + 360.0 : d; }
        inline float band(float4 lo, float4 hi, int i) { return i < 4 ? lo[i] : hi[i - 4]; }
    }

    """#

    private static let kernelSources: [String: String] = [
        "dk_perceptualLuma": #"""
    [[stitchable]] float4 dk_perceptualLuma(sample_t s) {
        float p = dk::toP(dk::luma(s.rgb));
        return float4(p, p, p, 1.0);
    }
    """#,
        "dk_darkChannel": #"""
    [[stitchable]] float4 dk_darkChannel(sample_t s) {
        float d = max(min(min(s.r, s.g), s.b), 0.0);
        return float4(d, d, d, 1.0);
    }
    """#,
        "dk_gfPack": #"""
    [[stitchable]] float4 dk_gfPack(sample_t i, sample_t p) {
        return float4(i.r, i.r * i.r, p.r, i.r * p.r);
    }
    """#,
        "dk_gfAB": #"""
    [[stitchable]] float4 dk_gfAB(sample_t m, float eps) {
        float varI = max(m.g - m.r * m.r, 0.0);
        float cov = m.a - m.r * m.b;
        float a = cov / (varI + eps);
        return float4(a, m.b - a * m.r, 0.0, 1.0);
    }
    """#,
        "dk_gfApply": #"""
    [[stitchable]] float4 dk_gfApply(sample_t i, sample_t ab) {
        float q = ab.r * i.r + ab.g;
        return float4(q, q, q, 1.0);
    }
    """#,
        "dk_tone": #"""
    [[stitchable]] float4 dk_tone(sample_t s, sample_t base, float4 a, float4 b) {
        float y = dk::luma(s.rgb);
        float p = dk::toP(max(y, 0.0));
        float bp = b.y > 0.5 ? mix(p, base.r, 0.8) : p;
        float p2 = dk::toneP(p, bp, a, b.x);
        return float4(dk::withP(s.rgb, max(y, 0.0), p, p2), s.a);
    }
    """#,
        "dk_detail": #"""
    [[stitchable]] float4 dk_detail(sample_t s, sample_t fine, sample_t coarse, sample_t clarityBase, float4 k) {
        float y = dk::luma(s.rgb);
        float p = dk::toP(max(y, 0.0));
        // Texture: band-pass detail (fine minus coarse blur) — skips pixel-level noise.
        float tex = fine.r - coarse.r;
        float kt = k.x > 0.0 ? 1.6 * k.x : 0.9 * k.x;
        float pt = p + kt * tex;
        // Clarity: detail relative to an edge-aware base, weighted to the midtones.
        float mid = clamp(1.0 - pow(2.0 * clamp(p, 0.0, 1.0) - 1.0, 2.0), 0.0, 1.0);
        float kc = k.y > 0.0 ? 0.9 * k.y : 0.7 * k.y;
        float p2 = pt + kc * (p - clarityBase.r) * mid;
        return float4(dk::withP(s.rgb, max(y, 0.0), p, p2), s.a);
    }
    """#,
        "dk_dehaze": #"""
    [[stitchable]] float4 dk_dehaze(sample_t s, sample_t darkBase, float amount) {
        float3 c = s.rgb;
        if (amount > 0.0) {
            // Dark channel prior with a white airlight: J = (I - w*d) / (1 - w*d).
            float w = 0.92 * amount;
            float hz = w * clamp(darkBase.r, 0.0, 1.0);
            float t = max(1.0 - hz, 0.2);
            c = (c - hz) / t;
            c = max(c, float3(-0.02));
        } else {
            float k = -amount * 0.45;
            float y = dk::luma(c);
            float3 haze = float3(0.55 + 0.35 * clamp(y, 0.0, 1.0));
            c = mix(c, haze, k * (0.6 + 0.4 * clamp(darkBase.r * 2.0, 0.0, 1.0)));
        }
        return float4(c, s.a);
    }
    """#,
        "dk_vibSat": #"""
    [[stitchable]] float4 dk_vibSat(sample_t s, float4 p) {
        float3 lab = dk::toOklab(s.rgb);
        float C = length(lab.yz);
        float h = atan2(lab.z, lab.y) * 57.29578;
        if (h < 0.0) { h += 360.0; }
        float gain = 1.0 + p.y;
        float lowSat = 1.0 - smoothstep(0.0, 0.18, C);
        if (p.x > 0.0) {
            // Skin tones (OkLCh hue ~ 25...85°, moderate chroma) are protected.
            float dh = abs(h - 55.0);
            float skin = (1.0 - smoothstep(22.0, 40.0, dh)) * (1.0 - smoothstep(0.1, 0.18, C));
            gain *= 1.0 + 1.0 * p.x * lowSat * (1.0 - 0.8 * skin);
        } else {
            gain *= 1.0 + p.x * (0.5 + 0.5 * lowSat);
        }
        lab.yz *= max(gain, 0.0);
        return float4(dk::fromOklab(lab), s.a);
    }
    """#,
        "dk_colorMixer": #"""
    [[stitchable]] float4 dk_colorMixer(sample_t s, float4 h0, float4 h1, float4 s0, float4 s1, float4 l0, float4 l1) {
        float3 lab = dk::toOklab(s.rgb);
        float C = length(lab.yz);
        if (C < 1e-4) { return s; }
        float h = atan2(lab.z, lab.y) * 57.29578;
        if (h < 0.0) { h += 360.0; }
        int i0, i1; float t;
        dk::bandWeights(h, i0, i1, t);
        float w0 = 1.0 - t, w1 = t;
        float hs0 = dk::band(h0, h1, i0), hs1 = dk::band(h0, h1, i1);
        float dh = w0 * hs0 * 0.6 * (hs0 > 0.0 ? dk::gapNext(i0) : dk::gapPrev(i0))
                 + w1 * hs1 * 0.6 * (hs1 > 0.0 ? dk::gapNext(i1) : dk::gapPrev(i1));
        float ds = w0 * dk::band(s0, s1, i0) + w1 * dk::band(s0, s1, i1);
        float dl = w0 * dk::band(l0, l1, i0) + w1 * dk::band(l0, l1, i1);
        // Near-neutral pixels have an unstable hue: fade the effect in with chroma.
        float f = smoothstep(0.0, 0.05, C);
        float hr = (h + dh * f) * 0.017453293;
        float C2 = C * max(1.0 + ds * f, 0.0);
        float L2 = lab.x * (1.0 + (dl > 0.0 ? 0.35 : 0.3) * dl * smoothstep(0.0, 0.03, C));
        return float4(dk::fromOklab(float3(L2, C2 * cos(hr), C2 * sin(hr))), s.a);
    }
    """#,
        "dk_vignette": #"""
    [[stitchable]] float4 dk_vignette(sample_t s, float4 rect, float4 p, destination dest) {
        float2 c = rect.xy + rect.zw * 0.5;
        float2 u = (dest.coord() - c) / (rect.zw * 0.5);         // -1...1 across the frame
        float roundness = p.z;
        // roundness > 0: towards a circle (in pixels); < 0: towards a rounded rectangle.
        float m = min(rect.z, rect.w);
        float2 axis = mix(float2(1.0), rect.zw / m, max(roundness, 0.0));
        float n = 2.0 + 6.0 * max(-roundness, 0.0);
        float2 v = abs(u * axis);
        float d = pow(pow(v.x, n) + pow(v.y, n), 1.0 / n) / pow(pow(axis.x, n) + pow(axis.y, n), 1.0 / n);
        float d0 = 0.25 + 0.7 * p.y;                              // midpoint
        float f = max(p.w, 0.02);                                 // feather
        float w = smoothstep(d0 * (1.0 - f), d0 + (1.2 - d0) * f, d);
        float y = dk::luma(s.rgb);
        float pp = dk::toP(max(y, 0.0));
        float amt = p.x;
        float p2 = amt < 0.0 ? pp * (1.0 + 0.95 * amt * w) : pp + (1.0 - min(pp, 1.0)) * 0.9 * amt * w;
        return float4(dk::withP(s.rgb, max(y, 0.0), pp, p2), s.a);
    }
    """#,
        "dk_grain": #"""
    [[stitchable]] float4 dk_grain(sample_t s, sample_t noise, float amount) {
        float y = dk::luma(s.rgb);
        float p = dk::toP(max(y, 0.0));
        float pc = clamp(p, 0.0, 1.0);
        float w = 0.35 + 2.6 * pc * (1.0 - pc);
        float p2 = p + (noise.r - 0.5) * amount * w;
        // Monochrome (luminance-only) grain.
        return float4(dk::withP(s.rgb, max(y, 0.0), p, p2), s.a);
    }
    """#,
    ]
}
