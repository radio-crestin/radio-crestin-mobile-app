package com.oguzhnatly.flutter_android_auto

data class FAATab(
    val contentId: String,
    val title: String,
    val contentRuntimeType: String,
    val contentData: Map<String, Any?>,
) {
    companion object {
        fun fromJson(map: Map<String, Any?>): FAATab {
            val contentId = map["contentId"] as? String ?: ""
            val title = map["title"] as? String ?: ""
            val contentRuntimeType = map["contentRuntimeType"] as? String ?: ""
            @Suppress("UNCHECKED_CAST")
            val contentData = (map["content"] as? Map<String, Any?>) ?: emptyMap()
            return FAATab(contentId, title, contentRuntimeType, contentData)
        }
    }
}
