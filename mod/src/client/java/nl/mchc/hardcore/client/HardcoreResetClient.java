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
 * Client HUD BOTTOM-LEFT: playtime this run, total playtime, and deaths per player.
 * Drawn compactly at 0.75x scale (via the pose matrix) so it's small but readable.
 *
 * Note: text colors MUST have an alpha byte (0xFF......), otherwise they are invisible.
 */
public class HardcoreResetClient implements ClientModInitializer {

	private static volatile long runSeconds = 0L;
	private static volatile long totalSeconds = 0L;
	private static volatile List<MchcStatsPayload.Entry> entries = new ArrayList<>();

	// ARGB (alpha required).
	private static final int PANEL_BG     = 0xB0000000;
	private static final int BORDER_LIGHT = 0x30FFFFFF;
	private static final int BORDER_DARK  = 0x60000000;
	private static final int COLOR_TIME   = 0xFFFFD24A; // gold-yellow (times)
	private static final int COLOR_LABEL  = 0xFFA8A8A8; // gray (headers)
	private static final int COLOR_P1     = 0xFF5CE65C; // green (player 1)
	private static final int COLOR_P2     = 0xFF5CB8FF; // blue (player 2)
	private static final int COLOR_P_REST = 0xFFFFFFFF; // white (extra players)

	private static final float SCALE  = 0.75f; // smaller than vanilla
	private static final int   MARGIN = 4;     // distance to screen edge (in real pixels)
	private static final int   PAD    = 4;     // inner padding (in scaled pixels)
	private static final int   GAP    = 1;     // space between rows (in scaled pixels)

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
			rows.add(new Row("Playtime this run", COLOR_LABEL));
			rows.add(new Row(formatTime(runSeconds), COLOR_TIME));
			rows.add(new Row("Total playtime", COLOR_LABEL));
			rows.add(new Row(formatTime(totalSeconds), COLOR_TIME));
			if (!snap.isEmpty()) {
				rows.add(new Row("Deaths", COLOR_LABEL));
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
			// Dimensions in SCALED pixels.
			int panelW = textW + PAD * 2;
			int panelH = rows.size() * line + (rows.size() - 1) * GAP + PAD * 2;

			// Place bottom-left; account for the scale to get the real screen position.
			int screenH = g.guiHeight();
			float originX = MARGIN;
			float originY = screenH - MARGIN - panelH * SCALE;

			var pose = g.pose();
			pose.pushMatrix();
			pose.translate(originX, originY);
			pose.scale(SCALE, SCALE);

			// From here I draw in scaled (local) coordinates, starting at (0,0).
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
