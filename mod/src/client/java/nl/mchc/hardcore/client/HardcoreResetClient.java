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
 * Client-kant: ontvangt de stats van de server en tekent een nette HUD-overlay
 * midden-links: totale speeltijd (uu:mm:ss) met daaronder de death counter per speler.
 */
public class HardcoreResetClient implements ClientModInitializer {

	// Laatst ontvangen waarden (volatile: gezet op netwerk-thread, gelezen op render-thread).
	private static volatile long playtimeSeconds = 0L;
	private static volatile List<MchcStatsPayload.Entry> entries = new ArrayList<>();

	private static final int PANEL_BG       = 0x80000000; // half-transparant zwart
	private static final int COLOR_TITLE    = 0xFFFFFF;   // wit
	private static final int COLOR_TIME     = 0xFFE54A;   // goud-geel
	private static final int COLOR_P1       = 0x6FE96F;   // groen
	private static final int COLOR_P2       = 0x6FB8FF;   // blauw
	private static final int COLOR_LABEL    = 0xB0B0B0;   // grijs

	@Override
	public void onInitializeClient() {
		ClientPlayNetworking.registerGlobalReceiver(MchcStatsPayload.TYPE, (payload, context) -> {
			playtimeSeconds = payload.playtimeSeconds();
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

	private static class StatsHudElement implements HudElement {
		@Override
		public void extractRenderState(GuiGraphicsExtractor g, DeltaTracker delta) {
			Minecraft mc = Minecraft.getInstance();
			if (mc == null || mc.font == null) return;
			if (mc.options != null && mc.options.hideGui) return;

			Font font = mc.font;
			List<MchcStatsPayload.Entry> snap = entries;

			String timeLabel = "Speeltijd";
			String timeValue = formatTime(playtimeSeconds);

			// Bepaal de breedte op basis van de langste regel.
			int maxText = Math.max(font.width(timeLabel), font.width(timeValue));
			List<String> deathLines = new ArrayList<>();
			for (MchcStatsPayload.Entry e : snap) {
				String line = e.name() + ": " + e.deaths();
				deathLines.add(line);
				maxText = Math.max(maxText, font.width(line));
			}

			int pad = 5;
			int line = font.lineHeight;
			int gap = 2;
			int rows = 2 /*label+time*/ + (deathLines.isEmpty() ? 0 : (1 + deathLines.size()));
			int panelW = maxText + pad * 2;
			int panelH = pad * 2 + rows * line + (rows - 1) * gap + (deathLines.isEmpty() ? 0 : gap);

			int screenH = g.guiHeight();
			int x = 4;
			int y = (screenH - panelH) / 2;   // verticaal gecentreerd, tegen de linkerrand

			g.fill(x, y, x + panelW, y + panelH, PANEL_BG);

			int tx = x + pad;
			int ty = y + pad;
			g.text(font, timeLabel, tx, ty, COLOR_LABEL);
			ty += line + gap;
			g.text(font, timeValue, tx, ty, COLOR_TIME);
			ty += line + gap;

			if (!deathLines.isEmpty()) {
				ty += gap;
				g.text(font, "Doden", tx, ty, COLOR_LABEL);
				ty += line + gap;
				for (int i = 0; i < deathLines.size(); i++) {
					int color = (i == 0) ? COLOR_P1 : (i == 1) ? COLOR_P2 : COLOR_TITLE;
					g.text(font, deathLines.get(i), tx, ty, color);
					ty += line + gap;
				}
			}
		}
	}
}
