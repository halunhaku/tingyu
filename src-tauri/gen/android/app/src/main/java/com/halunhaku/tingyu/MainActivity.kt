package com.halunhaku.tingyu

import android.os.Bundle
import android.view.View
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

class MainActivity : TauriActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)

    val contentView = findViewById<View>(android.R.id.content)
    ViewCompat.setOnApplyWindowInsetsListener(contentView) { view, windowInsets ->
      val safeArea = windowInsets.getInsets(
        WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
      )
      val gestures = windowInsets.getInsets(WindowInsetsCompat.Type.mandatorySystemGestures())

      view.setPadding(
        safeArea.left,
        safeArea.top,
        safeArea.right,
        maxOf(safeArea.bottom, gestures.bottom)
      )
      WindowInsetsCompat.CONSUMED
    }
    ViewCompat.requestApplyInsets(contentView)
  }
}
