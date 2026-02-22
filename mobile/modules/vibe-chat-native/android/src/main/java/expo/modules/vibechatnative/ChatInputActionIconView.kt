package expo.modules.vibechatnative

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.util.TypedValue
import android.view.View
import kotlin.math.min

internal enum class ChatInputActionIcon {
  ATTACH,
  MIC,
  SEND,
  RECORDING_DOT,
}

internal class ChatInputActionIconView(
  context: Context,
) : View(context) {
  var icon: ChatInputActionIcon = ChatInputActionIcon.MIC
    set(value) {
      if (field == value) return
      field = value
      invalidate()
    }

  var tintColor: Int = Color.WHITE
    set(value) {
      if (field == value) return
      field = value
      strokePaint.color = value
      fillPaint.color = value
      invalidate()
    }

  private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    color = tintColor
    strokeWidth = dpF(1.9f)
    strokeCap = Paint.Cap.ROUND
    strokeJoin = Paint.Join.ROUND
  }

  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = tintColor
  }

  private val path = Path()

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val side = min(width, height).toFloat()
    if (side <= 0f) return
    val left = (width - side) * 0.5f
    val top = (height - side) * 0.5f
    canvas.save()
    canvas.translate(left, top)
    when (icon) {
      ChatInputActionIcon.ATTACH -> drawAttach(canvas, side)
      ChatInputActionIcon.MIC -> drawMic(canvas, side)
      ChatInputActionIcon.SEND -> drawSend(canvas, side)
      ChatInputActionIcon.RECORDING_DOT -> drawRecordingDot(canvas, side)
    }
    canvas.restore()
  }

  private fun drawSend(canvas: Canvas, side: Float) {
    path.reset()
    path.moveTo(side * 0.18f, side * 0.52f)
    path.lineTo(side * 0.80f, side * 0.20f)
    path.lineTo(side * 0.59f, side * 0.81f)
    path.lineTo(side * 0.50f, side * 0.58f)
    path.lineTo(side * 0.18f, side * 0.52f)
    path.close()
    canvas.drawPath(path, fillPaint)

    path.reset()
    path.moveTo(side * 0.31f, side * 0.50f)
    path.lineTo(side * 0.55f, side * 0.57f)
    path.lineTo(side * 0.74f, side * 0.31f)
    canvas.drawPath(path, strokePaint.apply { color = withAlpha(tintColor, 0.30f) })
    strokePaint.color = tintColor
  }

  private fun drawRecordingDot(canvas: Canvas, side: Float) {
    canvas.drawCircle(side * 0.5f, side * 0.5f, side * 0.22f, fillPaint)
  }

  private fun drawMic(canvas: Canvas, side: Float) {
    val cx = side * 0.5f
    val top = side * 0.22f
    val bottom = side * 0.58f
    val radius = side * 0.16f
    // Capsule microphone head
    canvas.drawRoundRect(
      cx - radius,
      top,
      cx + radius,
      bottom,
      radius,
      radius,
      strokePaint,
    )
    // Stem
    canvas.drawLine(cx, bottom, cx, side * 0.72f, strokePaint)
    // Arc + base
    path.reset()
    path.moveTo(side * 0.30f, side * 0.56f)
    path.quadTo(cx, side * 0.76f, side * 0.70f, side * 0.56f)
    canvas.drawPath(path, strokePaint)
    canvas.drawLine(side * 0.38f, side * 0.80f, side * 0.62f, side * 0.80f, strokePaint)
  }

  private fun drawAttach(canvas: Canvas, side: Float) {
    // Paperclip silhouette drawn as a stroked path (SVG-like vector path).
    path.reset()
    path.moveTo(side * 0.62f, side * 0.28f)
    path.quadTo(side * 0.76f, side * 0.42f, side * 0.62f, side * 0.56f)
    path.lineTo(side * 0.42f, side * 0.76f)
    path.quadTo(side * 0.28f, side * 0.90f, side * 0.14f, side * 0.76f)
    path.quadTo(side * 0.02f, side * 0.64f, side * 0.12f, side * 0.52f)
    path.lineTo(side * 0.46f, side * 0.18f)
    path.quadTo(side * 0.58f, side * 0.06f, side * 0.70f, side * 0.18f)
    path.quadTo(side * 0.82f, side * 0.30f, side * 0.70f, side * 0.42f)
    path.lineTo(side * 0.36f, side * 0.76f)
    canvas.drawPath(path, strokePaint)
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val a = (alpha.coerceIn(0f, 1f) * 255f).toInt()
    return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )
}
