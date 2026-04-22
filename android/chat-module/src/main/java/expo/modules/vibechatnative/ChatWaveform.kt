package expo.modules.vibechatnative

import android.util.Base64
import org.json.JSONArray

internal fun parseNormalizedWaveform(raw: Any?): List<Float>? {
  when (raw) {
    null -> return null
    is JSONArray -> {
      return normalizeWaveformSamples((0 until raw.length()).map { raw.opt(it) })
    }
    is List<*> -> {
      return normalizeWaveformSamples(raw)
    }
    is ByteArray -> {
      return decodeTelegramWaveformBitstream(raw)
    }
    is String -> {
      val trimmed = raw.trim()
      if (trimmed.isEmpty()) return null

      if (trimmed.startsWith("[")) {
        val parsed = runCatching { JSONArray(trimmed) }.getOrNull()
        if (parsed != null) {
          normalizeWaveformSamples((0 until parsed.length()).map { parsed.opt(it) })?.let { return it }
        }
      }

      runCatching { Base64.decode(trimmed, Base64.DEFAULT) }
        .getOrNull()
        ?.takeIf { it.isNotEmpty() }
        ?.let { decoded ->
          decodeTelegramWaveformBitstream(decoded)?.let { return it }
        }

      val tokens =
        trimmed
          .split(',', ' ', '\n', '\t')
          .map(String::trim)
          .filter(String::isNotEmpty)
      return normalizeWaveformSamples(tokens)
    }
    else -> return null
  }
}

private fun normalizeWaveformSamples(values: List<*>): List<Float>? {
  val normalized =
    values
      .mapNotNull { item ->
        when (item) {
          is Number -> item.toFloat()
          is String -> item.toFloatOrNull()
          else -> null
        }
      }
      .filter { it.isFinite() }
      .map { it.coerceIn(0f, 1f) }
  return normalized.ifEmpty { null }
}

private fun decodeTelegramWaveformBitstream(bytes: ByteArray, bitsPerSample: Int = 5): List<Float>? {
  if (bytes.isEmpty() || bitsPerSample <= 0) return null

  val sampleCount = (bytes.size * 8) / bitsPerSample
  if (sampleCount <= 0) return null

  val maxValue = ((1 shl bitsPerSample) - 1).toFloat()
  if (maxValue <= 0f) return null

  val result = ArrayList<Float>(sampleCount)
  for (index in 0 until sampleCount) {
    val value = waveformBitValue(bytes, index * bitsPerSample, bitsPerSample)
    result.add((value / maxValue).coerceIn(0f, 1f))
  }
  return result.ifEmpty { null }
}

private fun waveformBitValue(bytes: ByteArray, bitOffset: Int, bitWidth: Int): Int {
  if (bytes.isEmpty() || bitWidth <= 0) return 0

  val byteOffset = bitOffset / 8
  if (byteOffset >= bytes.size) return 0

  val normalizedBitOffset = bitOffset % 8
  val mask = (1 shl bitWidth) - 1

  var value = 0
  val bytesToCopy = minOf(Int.SIZE_BYTES, bytes.size - byteOffset)
  for (index in 0 until bytesToCopy) {
    value = value or ((bytes[byteOffset + index].toInt() and 0xFF) shl (index * 8))
  }

  return (value shr normalizedBitOffset) and mask
}
