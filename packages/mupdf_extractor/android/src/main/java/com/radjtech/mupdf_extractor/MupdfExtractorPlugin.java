package com.radjtech.mupdf_extractor;

import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import com.artifex.mupdf.fitz.Document;
import com.artifex.mupdf.fitz.Font;
import com.artifex.mupdf.fitz.Image;
import com.artifex.mupdf.fitz.Matrix;
import com.artifex.mupdf.fitz.Page;
import com.artifex.mupdf.fitz.Point;
import com.artifex.mupdf.fitz.Quad;
import com.artifex.mupdf.fitz.Rect;
import com.artifex.mupdf.fitz.StructuredText;
import com.artifex.mupdf.fitz.StructuredTextWalker;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Extraction de texte structuré via MuPDF (AGPL) : spans par ligne avec
 * police réelle, taille réelle (matrices de texte déjà corrigées par
 * MuPDF) et boîtes par caractère. Jamais bloquant : toute erreur renvoie
 * null et l'app retombe sur ses autres extracteurs (PDFium FFI, bitmap).
 */
public class MupdfExtractorPlugin
        implements FlutterPlugin, MethodChannel.MethodCallHandler {

    private MethodChannel channel;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(), "mupdf_extractor");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull final MethodChannel.Result result) {
        if (!"extractPage".equals(call.method)) {
            result.notImplemented();
            return;
        }
        final String path = call.argument("path");
        final Integer pageIndex = call.argument("pageIndex");
        if (path == null || pageIndex == null) {
            result.success(null);
            return;
        }
        // Extraction hors du thread UI (MuPDF est synchrone et peut être
        // long sur de grosses pages).
        new Thread(new Runnable() {
            @Override
            public void run() {
                String json = null;
                try {
                    json = extractPage(path, pageIndex);
                } catch (Throwable t) {
                    json = null;
                }
                final String out = json;
                new Handler(Looper.getMainLooper()).post(new Runnable() {
                    @Override
                    public void run() {
                        result.success(out);
                    }
                });
            }
        }).start();
    }

    private String extractPage(String path, int pageIndex) throws JSONException {
        Document doc = Document.openDocument(path);
        if (doc == null) return null;
        try {
            if (pageIndex < 0 || pageIndex >= doc.countPages()) return null;
            Page page = doc.loadPage(pageIndex);
            if (page == null) return null;
            try {
                Rect bounds = page.getBounds();
                final double pageH = bounds.y1 - bounds.y0;
                StructuredText stext = page.toStructuredText();
                if (stext == null) return null;
                try {
                    Collector col = new Collector();
                    stext.walk(col);
                    return col.toJson(pageH, bounds);
                } finally {
                    stext.destroy();
                }
            } finally {
                page.destroy();
            }
        } finally {
            doc.destroy();
        }
    }

    /** Span = suite de caractères même police + même taille sur une ligne. */
    static class Span {
        String font = "";
        float size;
        final StringBuilder text = new StringBuilder();
        double x0 = Double.MAX_VALUE, y0 = Double.MAX_VALUE;
        double x1 = -Double.MAX_VALUE, y1 = -Double.MAX_VALUE;
        int chars = 0;
    }

    static class Line {
        final List<Span> spans = new ArrayList<>();
    }

    static class Collector implements StructuredTextWalker {
        final List<Line> lines = new ArrayList<>();
        private Line currentLine;
        private Span currentSpan;

        @Override
        public void onImageBlock(Rect bbox, Matrix transform, Image image) {
        }

        @Override
        public void beginTextBlock(Rect bbox) {
        }

        @Override
        public void endTextBlock() {
        }

        @Override
        public void beginLine(Rect bbox, int wmode, Point dir) {
            currentLine = new Line();
            currentSpan = null;
        }

        @Override
        public void endLine() {
            if (currentLine != null && !currentLine.spans.isEmpty()) {
                lines.add(currentLine);
            }
            currentLine = null;
            currentSpan = null;
        }

        @Override
        public void onChar(int c, Point origin, Font font, float size, Quad q) {
            if (currentLine == null) return;
            String fontName = font != null ? font.getName() : "";
            if (fontName == null) fontName = "";
            if (currentSpan == null
                    || !currentSpan.font.equals(fontName)
                    || Math.abs(currentSpan.size - size) > 0.01f) {
                currentSpan = new Span();
                currentSpan.font = fontName;
                currentSpan.size = size;
                currentLine.spans.add(currentSpan);
            }
            if (c > 0x20) {
                currentSpan.text.appendCodePoint(c);
            }
            currentSpan.chars++;
            double minX = Math.min(Math.min(q.ul_x, q.ur_x), Math.min(q.ll_x, q.lr_x));
            double maxX = Math.max(Math.max(q.ul_x, q.ur_x), Math.max(q.ll_x, q.lr_x));
            double minY = Math.min(Math.min(q.ul_y, q.ur_y), Math.min(q.ll_y, q.lr_y));
            double maxY = Math.max(Math.max(q.ul_y, q.ur_y), Math.max(q.ll_y, q.lr_y));
            if (minX < currentSpan.x0) currentSpan.x0 = minX;
            if (minY < currentSpan.y0) currentSpan.y0 = minY;
            if (maxX > currentSpan.x1) currentSpan.x1 = maxX;
            if (maxY > currentSpan.y1) currentSpan.y1 = maxY;
        }

        String toJson(double pageH, Rect bounds) throws JSONException {
            JSONObject root = new JSONObject();
            root.put("width", bounds.x1 - bounds.x0);
            root.put("height", pageH);
            JSONArray linesArr = new JSONArray();
            for (Line line : lines) {
                JSONArray spansArr = new JSONArray();
                for (Span s : line.spans) {
                    if (s.chars == 0 || s.x1 <= s.x0 || s.text.length() == 0) continue;
                    JSONObject o = new JSONObject();
                    o.put("text", s.text.toString());
                    o.put("font", s.font);
                    o.put("size", s.size);
                    // MuPDF : origine haut-gauche → conversion en origine
                    // bas-gauche (convention TextBlock du projet).
                    o.put("left", s.x0);
                    o.put("top", pageH - s.y0);
                    o.put("right", s.x1);
                    o.put("bottom", pageH - s.y1);
                    spansArr.put(o);
                }
                if (spansArr.length() > 0) {
                    JSONObject lo = new JSONObject();
                    lo.put("spans", spansArr);
                    linesArr.put(lo);
                }
            }
            root.put("lines", linesArr);
            return root.toString();
        }
    }
}
