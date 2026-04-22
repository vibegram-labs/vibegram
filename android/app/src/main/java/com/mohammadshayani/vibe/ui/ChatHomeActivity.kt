package com.mohammadshayani.vibe.ui

import android.content.Intent
import android.os.Bundle
import android.util.TypedValue
import android.view.Menu
import android.view.MenuItem
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import com.mohammadshayani.vibe.home.ChatHomeCardView
import com.mohammadshayani.vibe.home.ChatHomeListRow
import com.mohammadshayani.vibe.home.ChatHomeService
import com.mohammadshayani.vibe.storage.ChatEngineStore

class ChatHomeActivity : AppCompatActivity() {
  private lateinit var swipeRefreshLayout: SwipeRefreshLayout
  private lateinit var recyclerView: RecyclerView
  private val adapter = ChatHomeAdapter()

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    title = "Chats"

    swipeRefreshLayout = SwipeRefreshLayout(this).apply {
      setOnRefreshListener { loadChats() }
    }
    recyclerView = RecyclerView(this).apply {
      layoutManager = LinearLayoutManager(this@ChatHomeActivity)
      adapter = this@ChatHomeActivity.adapter
    }
    swipeRefreshLayout.addView(
      recyclerView,
      ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT,
      )
    )

    setContentView(swipeRefreshLayout)
    loadChats()
  }

  override fun onCreateOptionsMenu(menu: Menu): Boolean {
    menu.add(0, 1, 0, "Auth")
    menu.add(0, 2, 1, "Logout")
    return true
  }

  override fun onOptionsItemSelected(item: MenuItem): Boolean {
    return when (item.itemId) {
      1 -> {
        AuthSheetPresenter.show(
          activity = this,
          mode = AuthActivity.Mode.SIGN_IN,
          onAuthenticated = { loadChats() },
        )
        true
      }
      2 -> {
        ChatEngineStore.clearConfig(applicationContext)
        startActivity(Intent(this, WelcomeActivity::class.java))
        finish()
        true
      }
      else -> super.onOptionsItemSelected(item)
    }
  }

  private fun loadChats() {
    swipeRefreshLayout.isRefreshing = true
    ChatHomeService.fetchChats(applicationContext) { result ->
      swipeRefreshLayout.isRefreshing = false
      result.onSuccess { rows ->
        adapter.submit(rows)
      }.onFailure { error ->
        Toast.makeText(
          this,
          error.localizedMessage ?: error.message ?: "Load failed",
          Toast.LENGTH_LONG
        ).show()
      }
    }
  }

  private inner class ChatHomeAdapter : RecyclerView.Adapter<ChatHomeViewHolder>() {
    private val rows = ArrayList<ChatHomeListRow>()

    fun submit(nextRows: List<ChatHomeListRow>) {
      rows.clear()
      rows.addAll(nextRows)
      notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ChatHomeViewHolder {
      val view = ChatHomeCardView(parent.context)
      view.layoutParams = RecyclerView.LayoutParams(
        RecyclerView.LayoutParams.MATCH_PARENT,
        RecyclerView.LayoutParams.WRAP_CONTENT,
      )
      return ChatHomeViewHolder(view)
    }

    override fun onBindViewHolder(holder: ChatHomeViewHolder, position: Int) {
      val row = rows[position]
      holder.view.bind(
        row = row,
        isDark = true,
        avatarBackgroundColor = null,
        avatarGradientColors = null,
      )
      holder.view.setOnClickListener {
        Toast.makeText(
          this@ChatHomeActivity,
          "Conversation layout is the next native surface to wire here.",
          Toast.LENGTH_SHORT
        ).show()
      }
    }

    override fun getItemCount(): Int = rows.size
  }

  private class ChatHomeViewHolder(val view: ChatHomeCardView) : RecyclerView.ViewHolder(view)
}
