package com.example.scale_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

class ScaleWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        for (widgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.scale_widget)

            val weight = widgetData.getString("weight", "--") ?: "--"
            val fat = widgetData.getString("bodyFat", "--") ?: "--"
            val bmi = widgetData.getString("bmi", "--") ?: "--"
            val muscle = widgetData.getString("muscle", "--") ?: "--"
            val time = widgetData.getString("time", "") ?: ""

            views.setTextViewText(R.id.widget_weight, weight)
            views.setTextViewText(R.id.widget_fat, "$fat%")
            views.setTextViewText(R.id.widget_bmi, bmi)
            views.setTextViewText(R.id.widget_muscle, "$muscle%")
            views.setTextViewText(R.id.widget_time, time)

            // tap to open app
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = PendingIntent.getActivity(context, 0, intent, flags)
            views.setOnClickPendingIntent(R.id.widget_weight, pendingIntent)

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
