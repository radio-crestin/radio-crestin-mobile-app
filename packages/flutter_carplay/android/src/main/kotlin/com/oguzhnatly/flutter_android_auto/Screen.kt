package com.oguzhnatly.flutter_android_auto

import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarColor
import androidx.car.app.model.CarIcon
import androidx.car.app.model.CarText
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.Pane
import androidx.car.app.model.PaneTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.Tab
import androidx.car.app.model.TabContents
import androidx.car.app.model.TabTemplate
import androidx.car.app.model.Template
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
}

class PlayerScreen(carContext: CarContext) : Screen(carContext) {
    var stationTitle: String = ""
    var songTitle: String = ""
    var songArtist: String = ""
    var stationImage: CarIcon? = null
    var isPlaying: Boolean = false
    var isFavorite: Boolean = false

    override fun onGetTemplate(): Template {
        val paneBuilder = Pane.Builder()

        // Row 1: Song name
        val displaySongTitle = songTitle.ifEmpty { "..." }
        paneBuilder.addRow(
            Row.Builder()
                .setTitle(CarText.create(displaySongTitle))
                .build()
        )

        // Row 2: Artist
        if (songArtist.isNotEmpty()) {
            paneBuilder.addRow(
                Row.Builder()
                    .setTitle(CarText.create(songArtist))
                    .build()
            )
        }

        // Large centered thumbnail
        stationImage?.let { paneBuilder.setImage(it) }

        // Pane action 1: Play/Pause (prominent, red background)
        val playPauseIconName = if (isPlaying) "ic_pause" else "ic_play_arrow"
        loadDrawableIcon(playPauseIconName)?.let { icon ->
            paneBuilder.addAction(
                Action.Builder()
                    .setIcon(icon)
                    .setBackgroundColor(CarColor.RED)
                    .setOnClickListener {
                        FlutterAndroidAutoPlugin.sendEvent(
                            type = FAAChannelTypes.onPlayerPlayPause.name,
                            data = emptyMap()
                        )
                    }
                    .build()
            )
        }

        // Pane action 2: Favorite toggle
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

        // ActionStrip: Previous + Next
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
