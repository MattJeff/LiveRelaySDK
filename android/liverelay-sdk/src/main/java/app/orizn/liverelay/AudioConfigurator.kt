package app.orizn.liverelay

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

/**
 * Configuration AudioManager pour les appels temps réel.
 *
 * [configureForCommunication] passe en MODE_IN_COMMUNICATION et route vers le
 * haut-parleur (setCommunicationDevice sur API 31+, isSpeakerphoneOn en legacy).
 * [reset] restaure MODE_NORMAL.
 */
object AudioConfigurator {

    fun configureForCommunication(context: Context) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val speaker = audioManager.availableCommunicationDevices
                .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            if (speaker == null || !audioManager.setCommunicationDevice(speaker)) {
                // Fallback legacy si aucun haut-parleur intégré ou refus du système.
                @Suppress("DEPRECATION")
                audioManager.isSpeakerphoneOn = true
            }
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = true
        }
    }

    fun reset(context: Context) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = false
        }

        audioManager.mode = AudioManager.MODE_NORMAL
    }
}
