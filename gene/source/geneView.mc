import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class geneView extends WatchUi.DataField {

    private var mPlannedPaceStr as String = "--:--";
    private var mGapPaceStr     as String = "--:--";
    private var mCurrentPaceStr as String = "--:--";
    private var mDeltaStr       as String = "+0s";
    private var mGradeStr       as String = "0%";

    private var mTargetTimeSec as Float = 3600.0;
    private var mRaceDistanceM as Float = 10000.0;

    // EMA for raw pace smoothing (alpha=0.2)
    private var mPaceEma   as Float   = 0.0;
    private var mEmaReady  as Boolean = false;

    // 10-sample circular buffer for altitude + distance, sampled every 5 m
    // Window = 50 m regardless of pace — consistent noise characteristics for all runners
    private var mAltBuf        as Array = new [10];
    private var mDistBuf       as Array = new [10];
    private var mBufIdx        as Number = 0;
    private var mBufCount      as Number = 0;
    private var mLastSampleDist as Float = -999.0;

    function initialize() {
        DataField.initialize();

        var t = Application.Properties.getValue("targetTimeSec");
        var d = Application.Properties.getValue("raceDistanceM");
        if (t != null) { mTargetTimeSec = (t as Number).toFloat(); }
        if (d != null) { mRaceDistanceM = (d as Number).toFloat(); }

        mPlannedPaceStr = paceStr(mTargetTimeSec / mRaceDistanceM * 1609.344);

        for (var i = 0; i < 10; i++) {
            mAltBuf[i]  = 0.0;
            mDistBuf[i] = 0.0;
        }
        mLastSampleDist = -999.0;
    }

    function compute(info as Activity.Info) as Void {
        // --- Raw pace (EMA-smoothed) ---
        var speed = info.currentSpeed;
        if (speed != null && speed > 0.5) {
            var raw = 1609.344 / speed;
            mPaceEma  = mEmaReady ? 0.2 * raw + 0.8 * mPaceEma : raw;
            mEmaReady = true;
            mCurrentPaceStr = paceStr(mPaceEma);
        } else {
            mCurrentPaceStr = "--:--";
        }

        // --- Ahead / behind ---
        var dist  = info.elapsedDistance;
        var timer = info.timerTime;
        if (dist != null && timer != null && timer > 0) {
            var elapsedSec  = timer.toFloat() / 1000.0;
            var expectedDist = elapsedSec * mRaceDistanceM / mTargetTimeSec;
            var deltaSec     = (dist - expectedDist) * mTargetTimeSec / mRaceDistanceM;
            var dInt = deltaSec.toNumber();
            mDeltaStr = (dInt >= 0 ? "+" : "") + dInt.format("%d") + "s";
        }

        // --- Altitude buffer → grade → GAP ---
        var alt = info.altitude;
        if (alt != null && dist != null && (dist - mLastSampleDist) >= 5.0) {
            mAltBuf[mBufIdx]  = alt;
            mDistBuf[mBufIdx] = dist;
            mLastSampleDist   = dist;
            mBufIdx   = (mBufIdx + 1) % 10;
            if (mBufCount < 10) { mBufCount++; }

            if (mBufCount >= 2 && mEmaReady) {
                var newestIdx = (mBufIdx - 1 + 10) % 10;
                var oldestIdx = mBufCount < 10 ? 0 : mBufIdx;

                var deltaAlt  = (mAltBuf[newestIdx]  as Float) - (mAltBuf[oldestIdx]  as Float);
                var deltaDist = (mDistBuf[newestIdx] as Float) - (mDistBuf[oldestIdx] as Float);

                if (deltaDist > 1.0) {
                    var grade = deltaAlt / deltaDist;
                    if (grade >  0.30) { grade =  0.30; }
                    if (grade < -0.30) { grade = -0.30; }

                    mGradeStr = (grade >= 0 ? "+" : "") + (grade * 100).toNumber().format("%d") + "%";

                    // Minetti energy cost: C(i) = 155.4i^5 - 30.4i^4 - 43.3i^3 + 46.3i^2 + 19.5i + 3.6
                    var i2 = grade * grade;
                    var i3 = i2 * grade;
                    var i4 = i3 * grade;
                    var i5 = i4 * grade;
                    var c  = 155.4*i5 - 30.4*i4 - 43.3*i3 + 46.3*i2 + 19.5*grade + 3.6;

                    if (c > 0.0) {
                        mGapPaceStr = paceStr(mPaceEma * 3.6 / c);
                    }
                }
            }
        }
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        // Target pace
        dc.drawText(w / 2, h * 0.03, Graphics.FONT_TINY,   "target",        Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w / 2, h * 0.14, Graphics.FONT_MEDIUM, mPlannedPaceStr, Graphics.TEXT_JUSTIFY_CENTER);

        // GAP pace — hero metric
        dc.drawText(w / 2, h * 0.40, Graphics.FONT_TINY,   "GAP",           Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w / 2, h * 0.51, Graphics.FONT_MEDIUM, mGapPaceStr,     Graphics.TEXT_JUSTIFY_CENTER);

        // Bottom row: raw pace (left) | grade + delta (right)
        dc.drawText(w * 0.28, h * 0.83, Graphics.FONT_TINY, mCurrentPaceStr,              Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w * 0.72, h * 0.83, Graphics.FONT_TINY, mGradeStr + " " + mDeltaStr, Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function paceStr(secPerMile as Float) as String {
        var m = (secPerMile / 60).toNumber();
        var s = (secPerMile - m * 60).toNumber();
        return m.format("%d") + ":" + s.format("%02d");
    }
}
