package com.oguzhnatly.flutter_android_auto

import androidx.car.app.CarContext
import androidx.car.app.model.Action
import androidx.car.app.model.CarColor
import androidx.car.app.model.CarIcon
import androidx.car.app.model.CarText
import androidx.core.graphics.drawable.IconCompat
import androidx.car.app.model.GridItem
import androidx.car.app.model.GridTemplate
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.SectionedItemList
import androidx.car.app.model.Row
import androidx.car.app.model.Template
import androidx.car.app.Screen
import androidx.car.app.ScreenManager
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner


class FlutterAndroidAutoPlugin : FlutterPlugin, EventChannel.StreamHandler {
    private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    lateinit var channel: MethodChannel
    lateinit var eventChannel: EventChannel

    companion object {
        private const val TAG = "FlutterAndroidAuto"
        var events: EventChannel.EventSink? = null
        var currentTemplate: Template? = null
        var currentScreen: MainScreen? = null
        var currentPlayerScreen: PlayerScreen? = null

        fun sendEvent(type: String, data: Map<String, Any>) {
            events?.success(
                mapOf(
                    "type" to type, "data" to data
                )
            )
        }

        fun onAndroidAutoConnectionChange(status: FAAConnectionTypes) {
            sendEvent(
                type = FAAChannelTypes.onAndroidAutoConnectionChange.name,
                data = mapOf("status" to status.name)
            )
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            FAAHelpers.makeFCPChannelId("")
        )
        eventChannel = EventChannel(
            flutterPluginBinding.binaryMessenger,
            FAAHelpers.makeFCPChannelId("/event")
        )
        setUpHandlers()
    }

    private fun setUpHandlers() {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    FAAChannelTypes.forceUpdateRootTemplate.name -> forceUpdateRootTemplate(
                        call, result
                    )

                    FAAChannelTypes.setRootTemplate.name -> setRootTemplate(
                        call, result
                    )

                    FAAChannelTypes.pushTemplate.name -> pushTemplate(
                        call, result
                    )

                    FAAChannelTypes.popTemplate.name -> popTemplate(
                        call, result

                    )

                    FAAChannelTypes.popToRootTemplate.name -> popToRootTemplate(
                        call, result
                    )

                    FAAChannelTypes.onListItemSelectedComplete.name

                        -> onListItemSelectedComplete(
                        call, result
                    )

                    FAAChannelTypes.pushPlayerTemplate.name -> pushPlayerTemplate(
                        call, result
                    )

                    FAAChannelTypes.updatePlayerTemplate.name -> updatePlayerTemplate(
                        call, result
                    )

                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                e.printStackTrace()
                result.error("Error: $e", null, null)
            }
        }
        eventChannel.setStreamHandler(this)
    }

    private fun forceUpdateRootTemplate(
        call: MethodCall, result: MethodChannel.Result
    ) {
        val carContext = AndroidAutoService.session?.carContext
        if (carContext == null) {
            result.success(false)
            return
        }

        currentScreen?.let {
            it.invalidate()
            result.success(true)
        } ?: run {
            result.error(
                "No screen found", "You must set a RootTemplate first", null
            )
        }
    }

    private fun popTemplate(
        call: MethodCall, result: MethodChannel.Result
    ) {
        val carContext = AndroidAutoService.session?.carContext
        if (carContext == null) {
            result.success(false)
            return
        }

        val screenManager = carContext.getCarService(ScreenManager::class.java)
        if (screenManager.stackSize > 1) {
            screenManager.pop()
            result.success(true)
        } else {
            result.error("No screens to pop", "You are at root screen", null)
        }
    }

    private fun popToRootTemplate(
        call: MethodCall, result: MethodChannel.Result
    ) {
        val carContext = AndroidAutoService.session?.carContext
        if (carContext == null) {
            result.success(false)
            return
        }

        val screenManager = carContext.getCarService(ScreenManager::class.java)
        if (screenManager.stackSize > 1) {
            screenManager.popToRoot()
            result.success(true)
        } else {
            result.error("No screens to pop", "You are at root screen", null)
        }
    }


    private fun onListItemSelectedComplete(
        call: MethodCall, result: MethodChannel.Result
    ) {
        result.success(true)
    }

    private fun pushTemplate(
        call: MethodCall, result: MethodChannel.Result
    ) {
        val carContext = AndroidAutoService.session?.carContext
        if (carContext == null) {
            result.success(false)
            return
        }

        val runtimeType = call.argument<String>("runtimeType") ?: ""
        val data = call.argument<Map<String, Any?>>("template")!!
        val elementId = data["_elementId"] as? String ?: ""

        pluginScope.launch {
            try {
                val template = when (runtimeType) {
                    "FAAListTemplate" -> getListTemplate(
                        call, result, data
                    )
                    "FAAGridTemplate" -> getGridTemplate(
                        call, result, data
                    )

                    else -> null
                }
                if (template == null) {
                    result.error(
                        "Unsupported template type",
                        "Template type: $runtimeType is not supported",
                        null
                    )
                } else {
                    val newScreen = object : Screen(carContext) {
                        override fun onGetTemplate(): Template = template

                        init {
                            lifecycle.addObserver(object : LifecycleEventObserver {
                                override fun onStateChanged(
                                    source: LifecycleOwner, event: Lifecycle.Event
                                ) {
                                    when (event) {
                                        Lifecycle.Event.ON_DESTROY -> {
                                            sendEvent(
                                                type = FAAChannelTypes.onScreenBackButtonPressed.name,
                                                data = mapOf("elementId" to elementId)
                                            )
                                        }

                                        else -> {}
                                    }
                                }
                            })
                        }
                    }

                    carContext.getCarService(ScreenManager::class.java)
                        .push(newScreen)

                    result.success(true)
                }
            } catch (e: Exception) {
                e.printStackTrace()
                result.error("Error building template", e.message, null)
            }
        }
    }

    private fun setRootTemplate(
        call: MethodCall, result: MethodChannel.Result
    ) {
        val runtimeType = call.argument<String>("runtimeType") ?: ""
        val data = call.argument<Map<String, Any?>>("template")!!

        pluginScope.launch {
            try {
                if (runtimeType == "FAATabTemplate") {
                    setTabRootTemplate(data, result)
                    return@launch
                }

                val template = when (runtimeType) {
                    "FAAListTemplate" -> getListTemplate(
                        call, result, data, false
                    )
                    "FAAGridTemplate" -> getGridTemplate(
                        call, result, data, false
                    )

                    else -> null
                }

                if (template == null) {
                    result.error(
                        "Unsupported template type",
                        "Template type: $runtimeType is not supported",
                        null,
                    )
                } else {
                    // Switch off tab mode for non-tab templates
                    currentScreen?.isTabMode = false
                    currentTemplate = template
                    currentScreen?.invalidate()
                    result.success(true)
                }
            } catch (e: Exception) {
                e.printStackTrace()
                result.error("Error building template", e.message, null)
            }
        }
    }

    private suspend fun setTabRootTemplate(
        data: Map<String, Any?>,
        result: MethodChannel.Result
    ) = coroutineScope {
        val tabTemplate = FAATabTemplate.fromJson(data)
        val screen = currentScreen

        if (screen == null) {
            result.error("No screen", "MainScreen not available", null)
            return@coroutineScope
        }

        // Check if car supports TabTemplate (API level 6+)
        val carContext = AndroidAutoService.session?.carContext
        val apiLevel = carContext?.carAppApiLevel ?: 1

        if (apiLevel < 6) {
            // Fallback: build a flat ListTemplate with all stations for older head units
            Log.d(TAG, "Car API level $apiLevel < 6, using ListTemplate fallback")
            val fallbackTemplate = buildTabFallback(tabTemplate)
            screen.isTabMode = false
            currentTemplate = fallbackTemplate
            screen.invalidate()
            result.success(true)
            return@coroutineScope
        }

        Log.d(TAG, "Building TabTemplate with ${tabTemplate.tabs.size} tabs")

        // Build all content templates in parallel
        val contentTemplates = mutableMapOf<String, Template>()
        val buildJobs = tabTemplate.tabs.map { tab ->
            async {
                val content = buildTabContent(tab)
                tab.contentId to content
            }
        }
        for ((contentId, template) in buildJobs.awaitAll()) {
            if (template != null) {
                contentTemplates[contentId] = template
            }
        }

        // Preserve current active tab if already set, otherwise use default
        if (screen.activeTabId.isEmpty() ||
            !contentTemplates.containsKey(screen.activeTabId)) {
            screen.activeTabId = tabTemplate.activeTabContentId
        }

        screen.tabInfoList = tabTemplate.tabs
        screen.tabContentTemplates = contentTemplates
        screen.isTabMode = true
        screen.invalidate()
        result.success(true)
    }

    private suspend fun buildTabContent(tab: FAATab): Template? = coroutineScope {
        when (tab.contentRuntimeType) {
            "FAAGridTemplate" -> {
                val gridData = FAAGridTemplate.fromJson(tab.contentData)
                buildGridContent(gridData.buttons)
            }
            "FAAListTemplate" -> {
                val listData = FAAListTemplate.fromJson(tab.contentData)
                buildListContent(listData)
            }
            else -> null
        }
    }

    // Build a bare GridTemplate for tab content (no title, no header action)
    private suspend fun buildGridContent(
        buttons: List<FAAGridButton>
    ): Template = coroutineScope {
        val gridTemplateBuilder = GridTemplate.Builder()

        if (buttons.isEmpty()) {
            gridTemplateBuilder.setLoading(true)
        } else {
            gridTemplateBuilder.setLoading(false)

            val gridItems = buttons.map { button ->
                async {
                    val gridItemBuilder = GridItem.Builder()
                        .setTitle(CarText.create(button.title))

                    button.imageUrl?.let {
                        loadCarImageAsync(it)?.let { carIcon ->
                            gridItemBuilder.setImage(carIcon, GridItem.IMAGE_TYPE_LARGE)
                        }
                    }

                    if (button.isOnPressListenerActive) {
                        gridItemBuilder.setOnClickListener {
                            sendEvent(
                                type = FAAChannelTypes.onGridButtonPressed.name,
                                data = mapOf("elementId" to button.elementId)
                            )
                        }
                    }

                    gridItemBuilder.build()
                }
            }.awaitAll()

            val itemListBuilder = ItemList.Builder()
            for (gridItem in gridItems) {
                itemListBuilder.addItem(gridItem)
            }
            gridTemplateBuilder.setSingleList(itemListBuilder.build())
        }

        gridTemplateBuilder.build()
    }

    // Build a bare ListTemplate for tab content (no title, no header action)
    private suspend fun buildListContent(
        listData: FAAListTemplate
    ): Template = coroutineScope {
        val listTemplateBuilder = ListTemplate.Builder()

        if (listData.sections.isEmpty()) {
            listTemplateBuilder.setLoading(true)
        } else {
            listTemplateBuilder.setLoading(false)
            val isSingleList =
                listData.sections.size == 1 && listData.sections.first().title.isEmpty()

            if (isSingleList) {
                val rows = listData.sections.first().items.map { item ->
                    async { createRowFromItem(item) }
                }.awaitAll()
                val itemListBuilder = ItemList.Builder()
                for (row in rows) {
                    itemListBuilder.addItem(row)
                }
                listTemplateBuilder.setSingleList(itemListBuilder.build())
            } else {
                for (section in listData.sections) {
                    val rows = section.items.map { item ->
                        async { createRowFromItem(item) }
                    }.awaitAll()
                    val itemListBuilder = ItemList.Builder()
                    for (row in rows) {
                        itemListBuilder.addItem(row)
                    }
                    val sectionedItemList = SectionedItemList.create(
                        itemListBuilder.build(), section.title ?: ""
                    )
                    listTemplateBuilder.addSectionedList(sectionedItemList)
                }
            }
        }

        listTemplateBuilder.build()
    }

    // Fallback for cars with API level < 6: flat list with favorite stations
    // on top and all stations below, each as an expanded section.
    private suspend fun buildTabFallback(
        tabTemplate: FAATabTemplate
    ): Template = coroutineScope {
        val listTemplateBuilder = ListTemplate.Builder()
            .setTitle("Radio Crestin")

        for (tab in tabTemplate.tabs) {
            val rows = when (tab.contentRuntimeType) {
                "FAAGridTemplate" -> {
                    val gridData = FAAGridTemplate.fromJson(tab.contentData)
                    gridData.buttons.map { button ->
                        async {
                            val rowBuilder = Row.Builder()
                                .setTitle(CarText.create(button.title))

                            button.imageUrl?.let {
                                loadCarImageAsync(it)?.let { carIcon ->
                                    rowBuilder.setImage(carIcon)
                                }
                            }

                            if (button.isOnPressListenerActive) {
                                rowBuilder.setOnClickListener {
                                    sendEvent(
                                        type = FAAChannelTypes.onGridButtonPressed.name,
                                        data = mapOf("elementId" to button.elementId)
                                    )
                                }
                            }

                            rowBuilder.build()
                        }
                    }.awaitAll()
                }
                "FAAListTemplate" -> {
                    val listData = FAAListTemplate.fromJson(tab.contentData)
                    listData.sections.flatMap { section ->
                        section.items.map { item ->
                            async { createRowFromItem(item) }
                        }
                    }.awaitAll()
                }
                else -> emptyList()
            }

            if (rows.isNotEmpty()) {
                val itemListBuilder = ItemList.Builder()
                for (row in rows) {
                    itemListBuilder.addItem(row)
                }
                listTemplateBuilder.addSectionedList(
                    SectionedItemList.create(itemListBuilder.build(), tab.title)
                )
            }
        }

        // Add FAB on fallback root template
        val context = AndroidAutoService.session?.carContext
        if (context != null) {
            val resId = context.resources.getIdentifier(
                "ic_play_arrow", "drawable", context.packageName
            )
            if (resId != 0) {
                val icon = IconCompat.createWithResource(context, resId)
                val fabAction = Action.Builder()
                    .setIcon(CarIcon.Builder(icon).build())
                    .setBackgroundColor(CarColor.RED)
                    .setOnClickListener {
                        sendEvent(
                            type = FAAChannelTypes.onFabPressed.name,
                            data = mapOf("action" to "play")
                        )
                    }
                    .build()
                listTemplateBuilder.addAction(fabAction)
            }
        }

        listTemplateBuilder.build()
    }

    private fun pushPlayerTemplate(
        call: MethodCall, result: MethodChannel.Result
    ) {
        val carContext = AndroidAutoService.session?.carContext
        if (carContext == null) {
            result.error("No car context", "Android Auto not connected", null)
            return
        }

        pluginScope.launch {
            try {
                val data = call.arguments as Map<String, Any?>
                val screen = PlayerScreen(carContext)
                screen.stationTitle = data["stationTitle"] as? String ?: ""
                screen.songTitle = data["songTitle"] as? String ?: ""
                screen.songArtist = data["songArtist"] as? String ?: ""
                screen.isPlaying = data["isPlaying"] as? Boolean ?: false
                screen.isFavorite = data["isFavorite"] as? Boolean ?: false

                // Pre-load station image
                (data["imageUrl"] as? String)?.let { url ->
                    screen.stationImage = loadCarImageAsync(url)
                }

                // Send onPlayerClosed when screen is destroyed (back button)
                screen.lifecycle.addObserver(object : LifecycleEventObserver {
                    override fun onStateChanged(
                        source: LifecycleOwner, event: Lifecycle.Event
                    ) {
                        if (event == Lifecycle.Event.ON_DESTROY) {
                            currentPlayerScreen = null
                            sendEvent(
                                type = FAAChannelTypes.onPlayerClosed.name,
                                data = emptyMap()
                            )
                        }
                    }
                })

                currentPlayerScreen = screen
                carContext.getCarService(ScreenManager::class.java).push(screen)
                result.success(true)
            } catch (e: Exception) {
                e.printStackTrace()
                result.error("Error pushing player", e.message, null)
            }
        }
    }

    private fun updatePlayerTemplate(
        call: MethodCall, result: MethodChannel.Result
    ) {
        val screen = currentPlayerScreen
        if (screen == null) {
            result.success(false)
            return
        }

        pluginScope.launch {
            try {
                val data = call.arguments as Map<String, Any?>
                screen.stationTitle = data["stationTitle"] as? String ?: screen.stationTitle
                screen.songTitle = data["songTitle"] as? String ?: screen.songTitle
                screen.songArtist = data["songArtist"] as? String ?: screen.songArtist
                screen.isPlaying = data["isPlaying"] as? Boolean ?: screen.isPlaying
                screen.isFavorite = data["isFavorite"] as? Boolean ?: screen.isFavorite

                // Re-load image if URL changed
                (data["imageUrl"] as? String)?.let { url ->
                    screen.stationImage = loadCarImageAsync(url)
                }

                screen.invalidate()
                result.success(true)
            } catch (e: Exception) {
                e.printStackTrace()
                result.error("Error updating player", e.message, null)
            }
        }
    }

    private suspend fun getListTemplate(
        call: MethodCall,
        result: MethodChannel.Result,
        data: Map<String, Any?>,
        addBackButton: Boolean = true
    ): Template = coroutineScope {
        val template = FAAListTemplate.fromJson(data)
        val listTemplateBuilder =
            ListTemplate.Builder().setTitle(template.title)

        if (template.sections.size == 0) {
            listTemplateBuilder.setLoading(true)
        } else {
            listTemplateBuilder.setLoading(false)
            val isSingleList =
                template.sections.size == 1 && template.sections.first().title.isEmpty()

            if (isSingleList) {
                val sectionItems = template.sections.first().items
                // Load images in parallel for all items
                val rows = sectionItems.map { item ->
                    async { createRowFromItem(item) }
                }.awaitAll()
                val itemListBuilder = ItemList.Builder()
                for (row in rows) {
                    itemListBuilder.addItem(row)
                }
                listTemplateBuilder.setSingleList(itemListBuilder.build())
            } else {
                for (section in template.sections) {
                    // Load images in parallel within each section
                    val rows = section.items.map { item ->
                        async { createRowFromItem(item) }
                    }.awaitAll()
                    val itemListBuilder = ItemList.Builder()
                    for (row in rows) {
                        itemListBuilder.addItem(row)
                    }
                    val sectionedItemList = SectionedItemList.create(
                        itemListBuilder.build(), section.title ?: ""
                    )
                    listTemplateBuilder.addSectionedList(sectionedItemList)
                }
            }
        }

        if (addBackButton) {
            listTemplateBuilder.setHeaderAction(Action.BACK)
        }

        // Add FAB (bottom-right play button) on root template only
        if (!addBackButton) {
            val context = AndroidAutoService.session?.carContext
            if (context != null) {
                val resId = context.resources.getIdentifier(
                    "ic_play_arrow", "drawable", context.packageName
                )
                if (resId != 0) {
                    val icon = IconCompat.createWithResource(context, resId)
                    val fabAction = Action.Builder()
                        .setIcon(CarIcon.Builder(icon).build())
                        .setBackgroundColor(CarColor.RED)
                        .setOnClickListener {
                            sendEvent(
                                type = FAAChannelTypes.onFabPressed.name,
                                data = mapOf("action" to "play")
                            )
                        }
                        .build()
                    listTemplateBuilder.addAction(fabAction)
                }
            }
        }

        listTemplateBuilder.build()
    }

    // Helper function to create a Row from an FAAListItem, avoiding code duplication
    private suspend fun createRowFromItem(item: FAAListItem): Row {
        val rowBuilder = Row.Builder().setTitle(CarText.create(item.title))

        item.subtitle?.let { rowBuilder.addText(CarText.create(it)) }

        item.imageUrl?.let {
            loadCarImageAsync(it)?.let { carIcon ->
                rowBuilder.setImage(carIcon)
            }
        }

        if (item.isOnPressListenerActive) {
            rowBuilder.setOnClickListener {
                sendEvent(
                    type = FAAChannelTypes.onListItemSelected.name,
                    data = mapOf("elementId" to item.elementId)
                )
            }
        }

        // Add action buttons to the row
        for ((index, action) in item.actions.withIndex()) {
            val actionBuilder = Action.Builder()
                .setTitle(CarText.create(action.title))

            // Load icon if specified
            action.iconName?.let { iconName ->
                val context = AndroidAutoService.session?.carContext
                if (context != null) {
                    val resId = context.resources.getIdentifier(
                        iconName, "drawable", context.packageName
                    )
                    if (resId != 0) {
                        val icon = IconCompat.createWithResource(context, resId)
                        actionBuilder.setIcon(CarIcon.Builder(icon).build())
                    }
                }
            }

            if (action.isOnPressListenerActive) {
                actionBuilder.setOnClickListener {
                    sendEvent(
                        type = FAAChannelTypes.onListItemActionPressed.name,
                        data = mapOf(
                            "elementId" to item.elementId,
                            "actionIndex" to index
                        )
                    )
                }
            }

            rowBuilder.addAction(actionBuilder.build())
        }

        return rowBuilder.build()
    }

    private suspend fun getGridTemplate(
        call: MethodCall,
        result: MethodChannel.Result,
        data: Map<String, Any?>,
        addBackButton: Boolean = true
    ): Template = coroutineScope {
        val template = FAAGridTemplate.fromJson(data)
        val gridTemplateBuilder =
            GridTemplate.Builder().setTitle(template.title)

        if (template.buttons.isEmpty()) {
            gridTemplateBuilder.setLoading(true)
        } else {
            gridTemplateBuilder.setLoading(false)

            val gridItems = template.buttons.map { button ->
                async {
                    val gridItemBuilder = GridItem.Builder()
                        .setTitle(CarText.create(button.title))

                    button.imageUrl?.let {
                        loadCarImageAsync(it)?.let { carIcon ->
                            gridItemBuilder.setImage(carIcon, GridItem.IMAGE_TYPE_LARGE)
                        }
                    }

                    if (button.isOnPressListenerActive) {
                        gridItemBuilder.setOnClickListener {
                            sendEvent(
                                type = FAAChannelTypes.onGridButtonPressed.name,
                                data = mapOf("elementId" to button.elementId)
                            )
                        }
                    }

                    gridItemBuilder.build()
                }
            }.awaitAll()

            val itemListBuilder = ItemList.Builder()
            for (gridItem in gridItems) {
                itemListBuilder.addItem(gridItem)
            }
            gridTemplateBuilder.setSingleList(itemListBuilder.build())
        }

        if (addBackButton) {
            gridTemplateBuilder.setHeaderAction(Action.BACK)
        }

        gridTemplateBuilder.build()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        FlutterAndroidAutoPlugin.events = events
    }

    override fun onCancel(arguments: Any?) {
        events?.endOfStream()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }
}
