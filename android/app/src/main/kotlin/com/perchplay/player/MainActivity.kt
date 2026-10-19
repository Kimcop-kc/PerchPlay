package com.perchplay.player

import android.content.Context
import android.content.Intent
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaScannerConnection
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.vidflow/native"
    private val PIP_CHANNEL = "com.vidflow/pip"

    /// 抽音频的串行线程池：单线程保证同一时刻只有一段在解码。
    /// 实时字幕本来就是「上一段转写完才抽下一段」的串行语义，单线程足够，
    /// 也避免频繁 seek 时创建大量短命 Thread。
    private val extractExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { r ->
            Thread(r, "subtitle-extractor").apply { isDaemon = true }
        }

    override fun onPostResume() {
        super.onPostResume()
        // 高刷新率适配：请求当前分辨率下刷新率最高的显示模式
        applyHighRefreshRate()
    }

    /**
     * 在 60/90/120/144Hz 屏幕上以最高可用刷新率渲染。
     *
     * 只在刷新率确实更高时才切换，避免不必要的模式切换与耗电。
     */
    private fun applyHighRefreshRate() {
        try {
            val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay
            } ?: return

            val current = display.mode ?: return
            val best = display.supportedModes
                .filter {
                    it.physicalWidth == current.physicalWidth &&
                        it.physicalHeight == current.physicalHeight
                }
                .maxByOrNull { it.refreshRate } ?: return

            if (best.refreshRate > current.refreshRate + 0.1f) {
                window.attributes = window.attributes.apply {
                    preferredDisplayModeId = best.modeId
                }
            }
        } catch (_: Exception) {
            // 部分 ROM 不支持，忽略
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ────────── 通用 Native 方法 ──────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // ── 电池优化白名单 ──
                    "requestBatteryOptimization" -> {
                        requestBatteryOptimization()
                        result.success(true)
                    }

                    // ── 悬浮窗权限 ──
                    "requestOverlayPermission" -> {
                        requestOverlayPermission()
                        result.success(true)
                    }

                    // ── 自启动引导 ──
                    "requestAutoStart" -> {
                        openAutoStartSettings()
                        result.success(true)
                    }

                    // ── 打开应用设置 ──
                    "openAppSettings" -> {
                        openAppSettings()
                        result.success(true)
                    }

                    // ── 检测 ROM 品牌 ──
                    "getRomBrand" -> {
                        result.success(detectRomBrand())
                    }

                    // ── 检测是否 MIUI ──
                    "isMiui" -> {
                        result.success(isMiui())
                    }

                    // ── 检测是否 EMUI ──
                    "isEmui" -> {
                        result.success(isEmui())
                    }

                    // ── 检测是否 ColorOS ──
                    "isColorOS" -> {
                        result.success(isColorOS())
                    }

                    // ── 检查悬浮窗权限状态 ──
                    "canDrawOverlays" -> {
                        result.success(
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                Settings.canDrawOverlays(this)
                            } else {
                                true
                            }
                        )
                    }

                    // ── 检查电池优化状态 ──
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }

                    // ── 所有文件访问权限（Android 11+ 的 MANAGE_EXTERNAL_STORAGE）──
                    "hasAllFilesAccess" -> {
                        result.success(hasAllFilesAccess())
                    }

                    // ── 设备型号 / 系统（Dart 侧品牌识别用，缺了会导致
                    //    「系统优化」整块功能不显示）──
                    "getDeviceModel" -> {
                        result.success(
                            "${Build.MANUFACTURER} ${Build.MODEL}".trim()
                        )
                    }
                    "getSystemName" -> {
                        result.success("Android ${Build.VERSION.RELEASE}")
                    }

                    // ── 后台播放前台服务 ──
                    // 之前 Dart 侧从未启动过这个服务，「后台播放」开关等于空转；
                    // 现在按设置真正启停（持前台服务才能在息屏/内存回收下继续播）
                    "startBackgroundService" -> {
                        result.success(startBackgroundService())
                    }
                    "stopBackgroundService" -> {
                        result.success(stopBackgroundService())
                    }

                    // ── SSDP 组播锁 ──
                    // Android 默认会丢弃未持有 MulticastLock 的组播包，
                    // 没有它投屏搜设备永远搜不到
                    "acquireMulticastLock" -> {
                        result.success(acquireMulticast())
                    }
                    "releaseMulticastLock" -> {
                        releaseMulticast()
                        result.success(true)
                    }

                    // ── 直接跳到「所有文件访问」授权开关页 ──
                    "requestAllFilesAccess" -> {
                        openAllFilesAccessSettings()
                        result.success(true)
                    }

                    // ── 用 MediaStore 索引取全部视频（毫秒级，带时长/分辨率）──
                    "queryMediaStoreVideos" -> {
                        result.success(queryMediaStoreVideos())
                    }

                    // ── 文件被删除后让媒体库索引收敛（相册/其他播放器别再看到）──
                    "notifyMediaDeleted" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(notifyMediaDeleted(path))
                    }

                    // ── 抽一段音频转成 16kHz 单声道 WAV（实时 AI 字幕）──
                    "extractAudioSegment" -> {
                        val path = call.argument<String>("path") ?: ""
                        val startMs = call.argument<Int>("startMs") ?: 0
                        val durationMs = call.argument<Int>("durationMs") ?: 5000
                        // 串行线程池：复用一个后台线程，避免频繁 seek 时新建大量 Thread
                        extractExecutor.execute {
                            try {
                                val wav = extractAudioSegment(path, startMs, durationMs)
                                runOnUiThread { result.success(wav) }
                            } catch (e: Exception) {
                                Log.w("PerchPlay", "extractAudioSegment failed", e)
                                runOnUiThread { result.success(null) }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // ────────── 画中画 ──────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enterPip" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val params = android.app.PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(16, 9))
                                .setAutoEnterEnabled(true)
                                .setSeamlessResizeEnabled(true)
                                .build()
                            enterPictureInPictureMode(params)
                        }
                        result.success(true)
                    }
                    "isPipSupported" -> {
                        result.success(
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            packageManager.hasSystemFeature(
                                android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ──────────────────────────────
    // 后台播放前台服务
    // ──────────────────────────────

    private fun startBackgroundService(): Boolean {
        return try {
            val intent = Intent(this, BackgroundAudioService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (e: Exception) {
            Log.w("PerchPlay", "start background service failed", e)
            false
        }
    }

    private fun stopBackgroundService(): Boolean {
        return try {
            stopService(Intent(this, BackgroundAudioService::class.java))
            true
        } catch (e: Exception) {
            Log.w("PerchPlay", "stop background service failed", e)
            false
        }
    }

    // ──────────────────────────────
    // 音频抽取（实时 AI 字幕）
    // ──────────────────────────────

    /**
     * 从视频文件抽取 [startMs]~[startMs+durationMs] 的音频段，重采样为
     * 16kHz 单声道 16-bit PCM，写成临时 WAV 文件并返回路径。
     *
     * 与 libmpv（media_kit 播放内核）**完全解耦**：走 Android 系统
     * MediaExtractor + MediaCodec，对同一个文件单独解码一段。这样实时字幕
     * 不会影响正在播放的画面，暂停/seek 后也能立即抽当前位置的音频。
     *
     * 重采样用线性插值（16kHz → 目标采样率 16kHz 时源多为 44.1/48kHz，
     * 简单降采样足够 ASR 用）；双声道取平均。
     */
    private fun extractAudioSegment(path: String, startMs: Int, durationMs: Int): String? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
        } catch (e: Exception) {
            return null
        }

        // 找第一个音轨
        var trackIndex = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                trackIndex = i
                format = f
                break
            }
        }
        if (trackIndex < 0 || format == null) return null

        val sourceSampleRate =
            if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE))
                format.getInteger(MediaFormat.KEY_SAMPLE_RATE) else 44100
        val channelCount =
            if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT))
                format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 2

        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val decoder = MediaCodec.createDecoderByType(mime)
        decoder.configure(format, null, null, 0)
        decoder.start()

        extractor.selectTrack(trackIndex)
        // seek 到关键帧（会落在 startMs 之前最近的一个同步点）
        extractor.seekTo((startMs * 1000).toLong(), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

        val targetSampleRate = 16000
        val stopAtUs = (startMs + durationMs) * 1000L
        val pcm = ArrayList<Float>()

        // 解码器的**输出**参数要等 OUTPUT_FORMAT_CHANGED 才确定；
        // 先用输入格式兜底，收到变化后更新。
        var outSampleRate = sourceSampleRate
        var outChannelCount = channelCount

        // seek 到 PREVIOUS_SYNC 会落在 startMs 之前最近的关键帧，导致开头多出
        // 一段 startMs 之前的音频。记录首个样本的真实 PTS，最终按比例裁掉这
        // 段前缀，让字幕时间戳与「用户实际看的进度」对齐。
        var firstSampleTimeUs = -1L

        var inputDone = false
        var outputDone = false

        while (!outputDone) {
            // 喂输入
            if (!inputDone) {
                val inIndex = decoder.dequeueInputBuffer(10000)
                if (inIndex >= 0) {
                    val buf = decoder.getInputBuffer(inIndex)!!
                    val sampleSize = extractor.readSampleData(buf, 0)
                    val sampleTime = extractor.sampleTime
                    if (sampleSize < 0 || sampleTime < 0 || sampleTime >= stopAtUs) {
                        decoder.queueInputBuffer(
                            inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                        )
                        inputDone = true
                    } else {
                        if (firstSampleTimeUs < 0) firstSampleTimeUs = sampleTime
                        decoder.queueInputBuffer(inIndex, 0, sampleSize, sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            // 取输出
            val info = MediaCodec.BufferInfo()
            val outIndex = decoder.dequeueOutputBuffer(info, 10000)
            when {
                outIndex >= 0 -> {
                    if (info.size > 0) {
                        val buf = decoder.getOutputBuffer(outIndex)!!
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val bytes = ByteArray(info.size)
                        buf.get(bytes)
                        // 解码输出是 16-bit PCM（绝大多数情况；个别设备例外则忽略）
                        val samples = pcm16ToFloat(bytes)
                        // 降采样到 16kHz：按「帧」处理（每帧 outChannelCount 个样本）
                        val step = outSampleRate.toDouble() / targetSampleRate
                        val frameCount =
                            if (outChannelCount > 0) samples.size / outChannelCount else 0
                        var pos = 0.0
                        while (pos < frameCount) {
                            val i = pos.toInt() * outChannelCount
                            var sum = 0f
                            for (c in 0 until outChannelCount) {
                                sum += samples[i + c]
                            }
                            pcm.add(sum / outChannelCount)
                            pos += step
                        }
                    }
                    decoder.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                }
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val outFmt = decoder.outputFormat
                    outSampleRate =
                        if (outFmt.containsKey(MediaFormat.KEY_SAMPLE_RATE))
                            outFmt.getInteger(MediaFormat.KEY_SAMPLE_RATE) else outSampleRate
                    outChannelCount =
                        if (outFmt.containsKey(MediaFormat.KEY_CHANNEL_COUNT))
                            outFmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else outChannelCount
                }
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    // 继续
                }
            }
        }

        decoder.stop()
        decoder.release()
        extractor.release()

        // 裁掉 seek 回退关键帧多抽的前缀（firstSampleTimeUs < startMs*1000 时）
        if (firstSampleTimeUs > 0 && firstSampleTimeUs < startMs * 1000L) {
            val extraUs = startMs * 1000L - firstSampleTimeUs
            val extraSamples = (extraUs / 1000000.0 * targetSampleRate).toInt()
            if (extraSamples > 0 && extraSamples < pcm.size) {
                // 只去掉 extraSamples 个采样点；仍保留全部可能的风险由时长兜底
                val trimmed = ArrayList<Float>(pcm.subList(extraSamples, pcm.size))
                return writeSubtitleWav(trimmed, targetSampleRate)
            }
        }

        if (pcm.isEmpty()) return null

        // 写 WAV 文件
        return writeSubtitleWav(pcm, targetSampleRate)
    }

    /** 把 float 样本写成 16kHz 单声道 16-bit PCM WAV，返回文件路径 */
    private fun writeSubtitleWav(samples: ArrayList<Float>, sampleRate: Int): String? {
        if (samples.isEmpty()) return null
        val file = File(cacheDir, "live_sub_${System.currentTimeMillis()}.wav")
        writeWav(file, samples, sampleRate)
        return file.absolutePath
    }

    /** 把 16-bit PCM 字节数组转成 float 数组（跨声道排列） */
    private fun pcm16ToFloat(bytes: ByteArray): FloatArray {
        val shortCount = bytes.size / 2
        val out = FloatArray(shortCount)
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until shortCount) {
            out[i] = buf.short.toFloat() / 32768f
        }
        return out
    }

    /** 把 float 样本写成 16kHz 单声道 16-bit PCM WAV */
    private fun writeWav(file: File, samples: ArrayList<Float>, sampleRate: Int) {
        val dataSize = samples.size * 2
        val header = ByteArray(44)
        fun putInt(arr: ByteArray, off: Int, value: Int) {
            arr[off] = (value and 0xff).toByte()
            arr[off + 1] = ((value shr 8) and 0xff).toByte()
            arr[off + 2] = ((value shr 16) and 0xff).toByte()
            arr[off + 3] = ((value shr 24) and 0xff).toByte()
        }
        fun putShort(arr: ByteArray, off: Int, value: Int) {
            arr[off] = (value and 0xff).toByte()
            arr[off + 1] = ((value shr 8) and 0xff).toByte()
        }
        "RIFF".toByteArray().copyInto(header, 0)
        putInt(header, 4, 36 + dataSize)
        "WAVE".toByteArray().copyInto(header, 8)
        "fmt ".toByteArray().copyInto(header, 12)
        putInt(header, 16, 16) // PCM chunk size
        putShort(header, 20, 1) // audio format = PCM
        putShort(header, 22, 1) // channels = 1
        putInt(header, 24, sampleRate)
        putInt(header, 28, sampleRate * 2) // byte rate
        putShort(header, 32, 2) // block align
        putShort(header, 34, 16) // bits per sample
        "data".toByteArray().copyInto(header, 36)
        putInt(header, 40, dataSize)

        val data = ByteArray(dataSize)
        val dbuf = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) {
            val v = (s.coerceIn(-1f, 1f) * 32767f).toInt()
            dbuf.putShort(v.toShort())
        }
        file.writeBytes(header)
        file.appendBytes(data)
    }

    // ──────────────────────────────
    // SSDP 组播锁
    // ──────────────────────────────

    private var multicastLock: WifiManager.MulticastLock? = null

    private fun acquireMulticast(): Boolean {
        return try {
            if (multicastLock?.isHeld == true) return true
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("perchplay_cast").apply {
                setReferenceCounted(false)
                acquire()
            }
            true
        } catch (e: Exception) {
            Log.w("PerchPlay", "acquire multicast lock failed", e)
            false
        }
    }

    private fun releaseMulticast() {
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        multicastLock = null
    }

    override fun onDestroy() {
        extractExecutor.shutdownNow()
        releaseMulticast()
        super.onDestroy()
    }

    // ──────────────────────────────
    // 所有文件访问权限 + MediaStore 扫描
    // ──────────────────────────────

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true
        }
    }

    /**
     * 跳到系统「所有文件访问权限」开关页（其他播放器也是这么做的）。
     * 部分 ROM 没有应用级页面，退回总列表页。
     */
    private fun openAllFilesAccessSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            openAppSettings()
            return
        }
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (_: Exception) {
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Exception) {
                openAppSettings()
            }
        }
    }

    /**
     * 用系统媒体库索引查询视频。
     *
     * 比逐个目录遍历快几个数量级，而且自带时长/分辨率/修改时间，
     * 不用再为每个文件单独 stat 和探测。
     */
    private fun queryMediaStoreVideos(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val collection = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DATA,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.DATE_MODIFIED,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
            MediaStore.Video.Media.BUCKET_DISPLAY_NAME
        )
        try {
            contentResolver.query(
                collection, projection, null, null,
                "${MediaStore.Video.Media.DATE_MODIFIED} DESC"
            )?.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
                val dataCol = c.getColumnIndex(MediaStore.Video.Media.DATA)
                val nameCol = c.getColumnIndex(MediaStore.Video.Media.DISPLAY_NAME)
                val sizeCol = c.getColumnIndex(MediaStore.Video.Media.SIZE)
                val durCol = c.getColumnIndex(MediaStore.Video.Media.DURATION)
                val dateCol = c.getColumnIndex(MediaStore.Video.Media.DATE_MODIFIED)
                val wCol = c.getColumnIndex(MediaStore.Video.Media.WIDTH)
                val hCol = c.getColumnIndex(MediaStore.Video.Media.HEIGHT)
                val bucketCol =
                    c.getColumnIndex(MediaStore.Video.Media.BUCKET_DISPLAY_NAME)

                while (c.moveToNext()) {
                    // 真实路径：授予「所有文件访问」后 DATA 才有值
                    val path = if (dataCol >= 0 && !c.isNull(dataCol)) {
                        c.getString(dataCol)
                    } else {
                        null
                    } ?: continue
                    val name = if (nameCol >= 0 && !c.isNull(nameCol)) {
                        c.getString(nameCol)
                    } else {
                        path.substringAfterLast('/')
                    }
                    out.add(
                        mapOf(
                            "id" to c.getLong(idCol),
                            "path" to path,
                            "name" to name,
                            "size" to if (sizeCol >= 0) c.getLong(sizeCol) else 0L,
                            "duration" to if (durCol >= 0) c.getLong(durCol) else 0L,
                            "dateModified" to
                                (if (dateCol >= 0) c.getLong(dateCol) * 1000L else 0L),
                            "width" to if (wCol >= 0) c.getInt(wCol) else 0,
                            "height" to if (hCol >= 0) c.getInt(hCol) else 0,
                            "bucket" to
                                (if (bucketCol >= 0 && !c.isNull(bucketCol))
                                    c.getString(bucketCol) else null)
                        )
                    )
                }
            }
        } catch (e: Exception) {
            return emptyList()
        }
        return out
    }

    // ──────────────────────────────
    // 媒体库索引收敛
    // ──────────────────────────────

    /**
     * 通知系统媒体库「这个路径的文件已经不在了」。
     *
     * 直接在应用内删文件不会同步更新 MediaStore：相册和其它播放器还能看到
     * 一条指向不存在文件的记录。MediaScannerConnection.scanFile 会让系统重新
     * 扫这个路径，文件不存在时系统自己把索引记录删掉 —— 这正是删除文件后
     * 应该走的通道（不需要额外依赖，也不需要媒体写入权限）。
     *
     * 再补发一次旧的 ACTION_MEDIA_SCANNER_SCAN_FILE 广播：个别老 ROM 的媒体
     * 库只响应广播。Android 10+ 对该广播已废弃且可能抛异常，这里整段吞掉，
     * 主通道（scanFile）不受影响。
     */
    @Suppress("DEPRECATION")
    private fun notifyMediaDeleted(path: String): Boolean {
        if (path.isEmpty()) return false
        return try {
            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(path),
                null
            ) { _, _ -> }
            try {
                sendBroadcast(
                    Intent(
                        Intent.ACTION_MEDIA_SCANNER_SCAN_FILE,
                        Uri.fromFile(java.io.File(path))
                    )
                )
            } catch (_: Exception) {
                // 新系统上该广播已不可用，忽略：scanFile 已经通知过了
            }
            true
        } catch (e: Exception) {
            Log.w("PerchPlay", "notify media deleted failed", e)
            false
        }
    }

    // ──────────────────────────────
    // 中国 ROM 适配方法
    // ──────────────────────────────

    private fun requestBatteryOptimization() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                try {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                } catch (e: Exception) {
                    // 部分 ROM 不支持 → 打开应用设置
                    openAppSettings()
                }
            }
        }
    }

    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(this)) {
                try {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:$packageName")
                    ).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                } catch (e: Exception) {
                    openAppSettings()
                }
            }
        }
    }

    /**
     * 引导用户打开自启动设置
     * MIUI/EMUI/ColorOS/OriginOS 路径各不相同
     */
    private fun openAutoStartSettings() {
        try {
            when {
                isMiui() -> {
                    // MIUI 自启动管理
                    val intent = Intent().apply {
                        setClassName(
                            "com.miui.securitycenter",
                            "com.miui.permcenter.autostart.AutoStartManagementActivity"
                        )
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try {
                        startActivity(intent)
                        return
                    } catch (_: Exception) { }
                }
                isEmui() -> {
                    // 华为手机管家启动管理
                    val intent = Intent().apply {
                        setClassName(
                            "com.huawei.systemmanager",
                            "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
                        )
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try {
                        startActivity(intent)
                        return
                    } catch (_: Exception) { }
                }
                isColorOS() -> {
                    // OPPO/一加 自启动
                    val intent = Intent().apply {
                        setClassName(
                            "com.coloros.safecenter",
                            "com.coloros.safecenter.permission.startup.StartupAppListActivity"
                        )
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try {
                        startActivity(intent)
                        return
                    } catch (_: Exception) { }
                }
            }
            // fallback
            openAppSettings()
        } catch (_: Exception) {
            openAppSettings()
        }
    }

    private fun openAppSettings() {
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } catch (_: Exception) { }
    }

    // ──────────────────────────────
    // ROM 检测
    // ──────────────────────────────

    private fun detectRomBrand(): String {
        return when {
            isMiui() -> "MIUI"
            isEmui() -> "EMUI"
            isColorOS() -> "ColorOS"
            Build.MANUFACTURER.equals("vivo", ignoreCase = true) -> "OriginOS"
            else -> Build.MANUFACTURER ?: "Unknown"
        }
    }

    private fun isMiui(): Boolean {
        return try {
            val c = Class.forName("android.os.SystemProperties")
            val get = c.getMethod("get", String::class.java)
            val miuiVersion = get.invoke(c, "ro.miui.ui.version.name") as? String
            miuiVersion != null && miuiVersion.isNotBlank()
        } catch (_: Exception) {
            false
        }
    }

    private fun isEmui(): Boolean {
        return try {
            val c = Class.forName("android.os.SystemProperties")
            val get = c.getMethod("get", String::class.java)
            val emuiVersion = get.invoke(c, "ro.build.version.emui") as? String
            emuiVersion != null && emuiVersion.isNotBlank()
        } catch (_: Exception) {
            false
        }
    }

    private fun isColorOS(): Boolean {
        return try {
            val c = Class.forName("android.os.SystemProperties")
            val get = c.getMethod("get", String::class.java)
            val version = get.invoke(c, "ro.build.version.opporom") as? String
            version != null && version.isNotBlank()
        } catch (_: Exception) {
            false
        }
    }
}