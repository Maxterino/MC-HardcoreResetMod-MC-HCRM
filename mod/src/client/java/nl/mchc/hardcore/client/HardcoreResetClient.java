package nl.mchc.hardcore.client;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayNetworking;
import net.fabricmc.fabric.api.client.rendering.v1.hud.HudElement;
import net.fabricmc.fabric.api.client.rendering.v1.hud.HudElementRegistry;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.Font;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.resources.Identifier;
import nl.mchc.hardcore.MchcStatsPayload;

import java.util.ArrayList;
import java.util.List;

/**
 * Client-HUD LINKSONDER: speeltijd deze run, totale speeltijd, en doden per speler.
 * Compact getekend op 0.75x schaal (via de pose-matrix) zodat het klein maar leesbaar is.
 *
 * Let op: tekstkleuren MOETEN een alpha-byte (0xFF......) hebben, anders zijn ze onzichtbaar.
 */
public class HardcoreResetClient implements ClientModInitializer {

	private static volatile long runSeconds = 0L;
	private static volatile long totalSeconds = 0L;
	private static volatile List<MchcStatsPayload.Entry> entries = new ArrayList<>();

	// ARGB (alpha verplicht).
	private static final int PANEL_BG     = 0xB0000000;
	private static final int BORDER_LIGHT = 0x30FFFFFF;
	private static final int BORDER_DARK  = 0x60000000;
	private static final int COLOR_TIME   = 0xFFFFD24A; // goud-geel (tijden)
	private static final int COLOR_LABEL  = 0xFFA8A8A8; // grijs (kopjes)
	private static final int COLOR_P1     = 0xFF5CE65C; // groen (speler 1)
	private static final int COLOR_P2     = 0xFF5CB8FF; // blauw (speler 2)
	private static final int COLOR_P_REST = 0xFFFFFFFF; // wit (extra spelers)

	private static final float SCALE  = 0.75f; // kleiner dan vanilla
	private static final int   MARGIN = 4;     // afstand tot schermrand (in echte pixels)
	private static final int   PAD    = 4;     // binnenmarge (in geschaalde pixels)
	private static final int   GAP    = 1;     // ruimte tussen regels (in geschaalde pixels)

	@Override
	public void onInitializeClient() {
		ClientPlayNetworking.registerGlobalReceiver(MchcStatsPayload.TYPE, (payload, context) -> {
			runSeconds = payload.runSeconds();
			totalSeconds = payload.totalSeconds();
			entries = payload.entries();
		});

		HudElementRegistry.addLast(
				Identifier.fromNamespaceAndPath("mchc-hardcore", "stats_overlay"),
				new StatsHudElement()
		);
	}

	private static String formatTime(long totalSeconds) {
		long h = totalSeconds / 3600;
		long m = (totalSeconds % 3600) / 60;
		long s = totalSeconds % 60;
		return String.format("%02d:%02d:%02d", h, m, s);
	}

	private record Row(String text, int color) {
	}

	private static class StatsHudElement implements HudElement {
		@Override
		public void extractRenderState(GuiGraphicsExtractor g, DeltaTracker delta) {
			Minecraft mc = Minecraft.getInstance();
			if (mc == null || mc.font == null) return;
			if (mc.options != null && mc.options.hideGui) return;

			Font font = mc.font;
			List<MchcStatsPayload.Entry> snap = entries;

			List<Row> rows = new ArrayList<>();
			rows.add(new Row("Speeltijd deze run", COLOR_LABEL));
			rows.add(new Row(formatTime(runSeconds), COLOR_TIME));
			rows.add(new Row("Totale Speeltijd", COLOR_LABEL));
			rows.add(new Row(formatTime(totalSeconds), COLOR_TIME));
			if (!snap.isEmpty()) {
				rows.add(new Row("Doden", COLOR_LABEL));
				for (int i = 0; i < snap.size(); i++) {
					MchcStatsPayload.Entry e = snap.get(i);
					int color = (i == 0) ? COLOR_P1 : (i == 1) ? COLOR_P2 : COLOR_P_REST;
					rows.add(new Row(" " + e.name() + ": " + e.deaths(), color));
				}
			}

			int line = font.lineHeight;
			int textW = 0;
			for (Row r : rows) {
				textW = Math.max(textW, font.width(r.text()));
			}
			// Afmetingen in GESCHAALDE pixels.
			int panelW = textW + PAD * 2;
			int panelH = rows.size() * line + (rows.size() - 1) * GAP + PAD * 2;

			// Plaats linksonder; reken met de schaal voor de echte schermpositie.
			int screenH = g.guiHeight();
			float originX = MARGIN;
			float originY = screenH - MARGIN - panelH * SCALE;

			var pose = g.pose();
			pose.pushMatrix();
			pose.translate(originX, originY);
			pose.scale(SCALE, SCALE);

			// Vanaf hier teken ik in geschaalde (lokale) coördinaten, beginnend op (0,0).
			g.fill(0, 0, panelW, panelH, PANEL_BG);
			g.fill(0, 0, panelW, 1, BORDER_LIGHT);
			g.fill(0, 0, 1, panelH, BORDER_LIGHT);
			g.fill(0, panelH - 1, panelW, panelH, BORDER_DARK);
			g.fill(panelW - 1, 0, panelW, panelH, BORDER_DARK);

			int tx = PAD;
			int ty = PAD;
			for (Row r : rows) {
				g.text(font, r.text(), tx, ty, r.color(), true);
				ty += line + GAP;
			}

			pose.popMatrix();
		}
	}
}
