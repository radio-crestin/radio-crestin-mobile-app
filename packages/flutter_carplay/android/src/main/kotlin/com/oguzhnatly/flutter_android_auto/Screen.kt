package com.oguzhnatly.flutter_android_auto

import android.util.Log
import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.ScreenManager
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarColor
import androidx.car.app.model.CarIcon
import androidx.car.app.model.CarText
import androidx.car.app.model.Header
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.Pane
import androidx.car.app.model.PaneTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.SearchTemplate
import androidx.car.app.model.Tab
import androidx.car.app.model.TabContents
import androidx.car.app.model.TabTemplate
import androidx.car.app.model.Template
import androidx.car.app.media.model.MediaPlaybackTemplate
import androidx.core.graphics.drawable.IconCompat

class MainScreen(carContext: CarContext) : Screen(carContext) {
    // Tab mode state
    var isTabMode = false
    var activeTabId: String = ""
    var tabInfoList: List<FAATab> = emptyList()
    var tabContentTemplates: Map<String, Template> = emptyMap()

    // Map of contentId -> drawable resource name for tab icons
    private val tabIconMap = mapOf(
        "favorites" to "ic_favorite",
        "all_stations" to "ic_radio",
    )

    override fun onGetTemplate(): Template {
        if (isTabMode && tabContentTemplates.isNotEmpty() && tabInfoList.size >= 2) {
            return buildTabTemplate()
        }

        val appName =
            carContext.applicationInfo.loadLabel(carContext.packageManager)
                .toString() ?: ""

        return FlutterAndroidAutoPlugin.currentTemplate
            ?: ListTemplate.Builder().setTitle(appName).setLoading(true).build()
    }

    private fun buildTabTemplate(): Template {
        val tabCallback = object : TabTemplate.TabCallback {
            override fun onTabSelected(tabContentId: String) {
                activeTabId = tabContentId
                FlutterAndroidAutoPlugin.sendEvent(
                    type = FAAChannelTypes.onTabSelected.name,
                    data = mapOf("contentId" to tabContentId)
                )
                invalidate()
            }
        }

        val builder = TabTemplate.Builder(tabCallback)
            .setHeaderAction(Action.APP_ICON)

        for (tab in tabInfoList) {
            val tabBuilder = Tab.Builder()
                .setTitle(tab.title)
                .setContentId(tab.contentId)

            // Set icon (required by the Car App Library)
            val iconName = tabIconMap[tab.contentId] ?: "ic_radio"
            val resId = carContext.resources.getIdentifier(
                iconName, "drawable", carContext.packageName
            )
            if (resId != 0) {
                val icon = IconCompat.createWithResource(carContext, resId)
                tabBuilder.setIcon(CarIcon.Builder(icon).build())
            }

            builder.addTab(tabBuilder.build())
        }

        val activeContent = tabContentTemplates[activeTabId]
        if (activeContent != null) {
            builder.setTabContents(TabContents.Builder(activeContent).build())
        }

        builder.setActiveTabContentId(activeTabId)
        return builder.build()
    }

    private fun loadDrawableIcon(name: String): CarIcon? {
        val resId = carContext.resources.getIdentifier(
            name, "drawable", carContext.packageName
        )
        if (resId == 0) return null
        val icon = IconCompat.createWithResource(carContext, resId)
        return CarIcon.Builder(icon).build()
    }
}

/**
 * Now Playing screen using MediaPlaybackTemplate (API 8+).
 * The host renders album art, song title, artist, progress bar, and transport
 * controls automatically from the registered MediaSession. We only provide
 * the header with a back button and a favorite toggle.
 *
 * This gives the same native look as YouTube Music on Android Auto.
 */
class MediaPlaybackScreen(
    carContext: CarContext,
    var isFavorite: Boolean = false
) : Screen(carContext) {

    override fun onGetTemplate(): Template {
        val headerBuilder = Header.Builder()
            .setStartHeaderAction(Action.BACK)
            .setTitle(carContext.getString(
                carContext.resources.getIdentifier("aa_now_playing", "string", carContext.packageName)
            ))

        // Favorite toggle in the header (like YouTube Music's like button)
        val favIconName = if (isFavorite) "ic_favorite" else "ic_favorite_border"
        loadDrawableIcon(favIconName)?.let { icon ->
            headerBuilder.addEndHeaderAction(
                Action.Builder()
                    .setIcon(icon)
                    .setOnClickListener {
                        FlutterAndroidAutoPlugin.sendEvent(
                            type = FAAChannelTypes.onPlayerFavoriteToggle.name,
                            data = emptyMap()
                        )
                    }
                    .build()
            )
        }

        return MediaPlaybackTemplate.Builder()
            .setHeader(headerBuilder.build())
            .build()
    }

    private fun loadDrawableIcon(name: String): CarIcon? {
        val resId = carContext.resources.getIdentifier(
            name, "drawable", carContext.packageName
        )
        if (resId == 0) return null
        val icon = IconCompat.createWithResource(carContext, resId)
        return CarIcon.Builder(icon).build()
    }
}

/**
 * Search screen for finding stations by name.
 * Results are sent as events to Flutter, which filters stations and sends
 * back results via updateSearchResults().
 */
class SearchScreen(carContext: CarContext) : Screen(carContext) {
    var searchResults: ItemList = ItemList.Builder().build()
    var isLoading: Boolean = false

    override fun onGetTemplate(): Template {
        return SearchTemplate.Builder(
            object : SearchTemplate.SearchCallback {
                override fun onSearchTextChanged(searchText: String) {
                    FlutterAndroidAutoPlugin.sendEvent(
                        type = FAAChannelTypes.onSearchTextChanged.name,
                        data = mapOf("query" to searchText)
                    )
                }

                override fun onSearchSubmitted(searchText: String) {
                    FlutterAndroidAutoPlugin.sendEvent(
                        type = FAAChannelTypes.onSearchTextChanged.name,
                        data = mapOf("query" to searchText)
                    )
                }
            }
        )
            .setHeaderAction(Action.BACK)
            .setItemList(searchResults)
            .setLoading(isLoading)
            .setSearchHint(carContext.getString(
                carContext.resources.getIdentifier("aa_search_hint", "string", carContext.packageName)
            ))
            .setShowKeyboardByDefault(true)
            .build()
    }
}

/**
 * Legacy Now Playing screen using PaneTemplate.
 * Used as fallback on car hosts that don't support API level 8
 * (MediaPlaybackTemplate). Manually syncs UI from Flutter state.
 */
class PlayerScreen(carContext: CarContext) : Screen(carContext) {
    var stationTitle: String = ""
    var songTitle: String = ""
    var songArtist: String = ""
    var stationImage: CarIcon? = null
    var isPlaying: Boolean = false
    var isFavorite: Boolean = false

    // Brand primary color (#E91E63)
    private val brandPink = CarColor.createCustom(0xFFE91E63.toInt(), 0xFFF8BBD0.toInt())

    override fun onGetTemplate(): Template {
        val paneBuilder = Pane.Builder()

        // Row 1: Song title
        val loadingText = carContext.getString(
            carContext.resources.getIdentifier("aa_loading", "string", carContext.packageName)
        )
        val displaySongTitle = songTitle.ifEmpty { loadingText }
        paneBuilder.addRow(
            Row.Builder()
                .setTitle(CarText.create(displaySongTitle))
                .build()
        )

        // Row 2: Artist (only if different from song title)
        val displayArtist = songArtist.ifEmpty { stationTitle }
        if (displayArtist.isNotEmpty() && displayArtist != displaySongTitle) {
            paneBuilder.addRow(
                Row.Builder()
                    .setTitle(CarText.create(displayArtist))
                    .build()
            )
        }

        // Station artwork (displayed on the right side by the Template Host)
        stationImage?.let { paneBuilder.setImage(it) }

        // Play/Pause button with brand pink color
        val playPauseIconName = if (isPlaying) "ic_pause" else "ic_play_arrow"
        loadDrawableIcon(playPauseIconName)?.let { icon ->
            paneBuilder.addAction(
                Action.Builder()
                    .setIcon(icon)
                    .setBackgroundColor(brandPink)
                    .setOnClickListener {
                        FlutterAndroidAutoPlugin.sendEvent(
                            type = FAAChannelTypes.onPlayerPlayPause.name,
                            data = emptyMap()
                        )
                    }
                    .build()
            )
        }

        // Favorite toggle button
        val favIconName = if (isFavorite) "ic_favorite" else "ic_favorite_border"
        loadDrawableIcon(favIconName)?.let { icon ->
            paneBuilder.addAction(
                Action.Builder()
                    .setIcon(icon)
                    .setOnClickListener {
                        FlutterAndroidAutoPlugin.sendEvent(
                            type = FAAChannelTypes.onPlayerFavoriteToggle.name,
                            data = emptyMap()
                        )
                    }
                    .build()
            )
        }

        // Header ActionStrip: Previous + Next
        val actionStripBuilder = ActionStrip.Builder()

        loadDrawableIcon("ic_skip_previous")?.let { icon ->
            actionStripBuilder.addAction(
                Action.Builder()
                    .setIcon(icon)
                    .setOnClickListener {
                        FlutterAndroidAutoPlugin.sendEvent(
                            type = FAAChannelTypes.onPlayerPrevious.name,
                            data = emptyMap()
                        )
                    }
                    .build()
            )
        }

        loadDrawableIcon("ic_skip_next")?.let { icon ->
            actionStripBuilder.addAction(
                Action.Builder()
                    .setIcon(icon)
                    .setOnClickListener {
                        FlutterAndroidAutoPlugin.sendEvent(
                            type = FAAChannelTypes.onPlayerNext.name,
                            data = emptyMap()
                        )
                    }
                    .build()
            )
        }

        return PaneTemplate.Builder(paneBuilder.build())
            .setHeaderAction(Action.BACK)
            .setTitle(stationTitle)
            .setActionStrip(actionStripBuilder.build())
            .build()
    }

    private fun loadDrawableIcon(name: String): CarIcon? {
        val resId = carContext.resources.getIdentifier(
            name, "drawable", carContext.packageName
        )
        if (resId == 0) return null
        val icon = IconCompat.createWithResource(carContext, resId)
        return CarIcon.Builder(icon).build()
    }
}
