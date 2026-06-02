package nl.mchc.hardcore;

import com.mojang.brigadier.CommandDispatcher;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.command.v2.CommandRegistrationCallback;
import net.fabricmc.fabric.api.entity.event.v1.ServerLivingEntityEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerTickEvents;
import net.fabricmc.fabric.api.networking.v1.PayloadTypeRegistry;
import net.fabricmc.fabric.api.networking.v1.ServerPlayConnectionEvents;
import net.fabricmc.fabric.api.networking.v1.ServerPlayNetworking;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;
import net.minecraft.network.protocol.common.ClientboundTransferPacket;
import net.minecraft.network.protocol.game.ClientboundSetSubtitleTextPacket;
import net.minecraft.network.protocol.game.ClientboundSetTitleTextPacket;
import net.minecraft.network.protocol.game.ClientboundSetTitlesAnimationPacket;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerPlayer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Properties;

/**
 * MCHC Hardcore Reset (server-side).
 *
 * Flow per actieve server (alpha/beta) bij een dood:
 *  1. Speler sterft -> grote titel naar alle spelers, 5 sec aftellen. Direct wake-<partner>.
 *  2a. Doet niemand iets binnen 5 sec  -> automatisch doorgaan (transfer + reset).
 *  2b. Klikt iemand "Spectate World" (wordt spectator) binnen die 5 sec -> aftellen ANNULEREN.
 *      Daarna gebeurt er niets tot je in de server-console 'next' typt.
 *  3. Doorgaan = alle spelers via de vanilla transfer-packet naar de standby sturen,
 *     daarna deze server stoppen zodat run.bat de wereld wist + nieuwe seed zet + herstart.
 *
 * Console-commando 'next' forceert het doorgaan (ook tijdens het aftellen of de pauze).
 *
 * Stats (control/stats.properties): run-timer, totale timer, doden per speler -> naar HUD.
 */
public class HardcoreReset implements ModInitializer {
	public static final String MOD_ID = "mchc-hardcore";
	private static final Logger LOGGER = LoggerFactory.getLogger(MOD_ID);

	private String serverName = "alpha";
	private String partnerName = "beta";
	private int partnerPort = 25567;
	private Path controlDir = Paths.get("..", "control");
	private int countdownSeconds = 5;
	private String titleTemplate = "%player% is dood gegaan";
	private String subtitleText = "Kaulo slecht lol, wereld wordt gereset";
	private String localTransferHost = "127.0.0.1";
	private String publicTransferHost = "";

	private enum Phase { IDLE, COUNTDOWN, MANUAL, WAIT_PARTNER, WAIT_EMPTY }

	private Phase phase = Phase.IDLE;
	private int countdownTicks = 0;
	private int waitEmptyTicks = 0;
	private volatile boolean nextRequested = false;
	private MinecraftServer server;
	private StatsStore stats;
	private long accumulatedMillis = 0L;
	private long lastTickMillis = 0L;
	private int saveCooldown = 0;

	@Override
	public void onInitialize() {
		loadConfig();
		stats = new StatsStore(controlDir);

		PayloadTypeRegistry.clientboundPlay().register(MchcStatsPayload.TYPE, MchcStatsPayload.CODEC);

		LOGGER.info("[MCHC] HardcoreReset geladen. server='{}', partner='{}' (poort {}), control='{}'.",
				serverName, partnerName, partnerPort, controlDir.toAbsolutePath());

		CommandRegistrationCallback.EVENT.register((dispatcher, registryAccess, environment) ->
				registerNextCommand(dispatcher));

		ServerLifecycleEvents.SERVER_STARTED.register(srv -> {
			this.server = srv;
			stats.load();
			lastTickMillis = System.currentTimeMillis();

			// Death screen MOET zichtbaar zijn (knop "Spectate World"), dus GEEN immediate respawn.
			runCommand(srv, "gamerule doImmediateRespawn false");

			try {
				Files.createDirectories(controlDir);
				Files.deleteIfExists(activeFlag());
				Files.deleteIfExists(resetNowFlag());
				Files.writeString(readyFlag(), Long.toString(System.currentTimeMillis()));
				LOGGER.info("[MCHC] '{}' staat klaar als standby-wereld.", serverName);
			} catch (IOException e) {
				LOGGER.error("[MCHC] Kon control-bestanden niet aanmaken", e);
			}
		});

		ServerLifecycleEvents.SERVER_STOPPING.register(srv -> {
			stats.save();
			try {
				Files.deleteIfExists(readyFlag());
				Files.deleteIfExists(activeFlag());
			} catch (IOException ignored) {
			}
		});

		ServerPlayConnectionEvents.JOIN.register((handler, sender, srv) -> {
			stats.load();
			stats.ensurePlayer(handler.player.getName().getString());
			stats.save();
			updateActiveFlag();
			sendStatsToAll();
		});
		ServerPlayConnectionEvents.DISCONNECT.register((handler, srv) -> updateActiveFlag());

		ServerLivingEntityEvents.AFTER_DEATH.register((entity, source) -> {
			if (!(entity instanceof ServerPlayer player)) return;
			String name = player.getName().getString();
			stats.recordDeath(name);
			stats.save();
			sendStatsToAll();
			if (phase == Phase.IDLE) {
				startReset(name);
			}
		});

		ServerTickEvents.END_SERVER_TICK.register(this::onTick);
	}

	private void registerNextCommand(CommandDispatcher<CommandSourceStack> dispatcher) {
		dispatcher.register(Commands.literal("next").executes(ctx -> {
			nextRequested = true;
			ctx.getSource().sendSystemMessage(Component.literal(
					"[MCHC] 'next' ontvangen - er wordt nu doorgeschakeld naar de volgende wereld."));
			LOGGER.info("[MCHC] 'next' commando ontvangen op '{}'.", serverName);
			return 1;
		}));
	}

	private void startReset(String deadPlayer) {
		LOGGER.info("[MCHC] '{}' is dood. Aftellen ({}s) op '{}'. Klik 'Spectate World' om te annuleren.",
				deadPlayer, countdownSeconds, serverName);
		phase = Phase.COUNTDOWN;
		countdownTicks = Math.max(1, countdownSeconds * 20);
		nextRequested = false;
		try {
			Files.writeString(wakePartnerFlag(), Long.toString(System.currentTimeMillis()));
		} catch (IOException e) {
			LOGGER.error("[MCHC] Kon wake-flag voor partner niet schrijven", e);
		}
		broadcastTitle(deadPlayer);
	}

	private boolean anyoneSpectating() {
		if (server == null) return false;
		for (ServerPlayer p : server.getPlayerList().getPlayers()) {
			if (p.isSpectator()) return true;
		}
		return false;
	}

	private void onTick(MinecraftServer srv) {
		// Speeltijd + HUD-stats (per seconde).
		long now = System.currentTimeMillis();
		long delta = now - lastTickMillis;
		lastTickMillis = now;
		if (!srv.getPlayerList().getPlayers().isEmpty()) {
			accumulatedMillis += delta;
			while (accumulatedMillis >= 1000L) {
				accumulatedMillis -= 1000L;
				stats.addSecond();
				sendStatsToAll();
				if (--saveCooldown <= 0) {
					saveCooldown = 5;
					stats.save();
				}
			}
		}

		switch (phase) {
			case COUNTDOWN -> {
				if (nextRequested) {
					LOGGER.info("[MCHC] Handmatig doorgaan ('next').");
					phase = Phase.WAIT_PARTNER;
				} else if (anyoneSpectating()) {
					LOGGER.info("[MCHC] 'Spectate World' gekozen - reset GEPAUZEERD. "
							+ "Typ 'next' in deze console om alsnog naar de volgende wereld te gaan.");
					phase = Phase.MANUAL;
				} else if (--countdownTicks <= 0) {
					phase = Phase.WAIT_PARTNER;
				}
			}
			case MANUAL -> {
				if (nextRequested) {
					phase = Phase.WAIT_PARTNER;
				}
			}
			case WAIT_PARTNER -> {
				if (Files.exists(partnerReadyFlag())) {
					transferAllPlayers(srv);
					phase = Phase.WAIT_EMPTY;
					waitEmptyTicks = 20 * 15;
				} else {
					// partner nog niet wakker? blijf wachten (wake-flag staat al gezet)
				}
			}
			case WAIT_EMPTY -> {
				if (srv.getPlayerList().getPlayers().isEmpty() || --waitEmptyTicks <= 0) {
					LOGGER.info("[MCHC] Spelers verplaatst. '{}' stopt voor wereld-reset.", serverName);
					stats.resetRun();   // run-timer reset; totaal blijft staan
					stats.save();
					phase = Phase.IDLE;
					nextRequested = false;
					try {
						Files.writeString(resetNowFlag(), Long.toString(System.currentTimeMillis()));
					} catch (IOException ignored) {
					}
					runCommand(srv, "stop");
				}
			}
			default -> {
			}
		}
	}

	private void transferAllPlayers(MinecraftServer srv) {
		for (ServerPlayer p : srv.getPlayerList().getPlayers()) {
			String host = transferHostFor(p);
			LOGGER.info("[MCHC] Transfer {} -> {}:{}", p.getName().getString(), host, partnerPort);
			p.connection.send(new ClientboundTransferPacket(host, partnerPort));
		}
	}

	private String transferHostFor(ServerPlayer p) {
		boolean loopback = false;
		try {
			SocketAddress sa = p.connection.getRemoteAddress();
			if (sa instanceof InetSocketAddress isa) {
				InetAddress addr = isa.getAddress();
				loopback = addr != null && (addr.isLoopbackAddress() || addr.isAnyLocalAddress());
			}
		} catch (Exception ignored) {
		}
		if (loopback) return localTransferHost;
		if (!publicTransferHost.isBlank()) return publicTransferHost;
		return localTransferHost;
	}

	private void sendStatsToAll() {
		if (server == null) return;
		MchcStatsPayload payload =
				new MchcStatsPayload(stats.runSeconds(), stats.totalSeconds(), stats.entries());
		for (ServerPlayer p : server.getPlayerList().getPlayers()) {
			if (ServerPlayNetworking.canSend(p, MchcStatsPayload.TYPE)) {
				ServerPlayNetworking.send(p, payload);
			}
		}
	}

	private void updateActiveFlag() {
		if (server == null) return;
		boolean active = !server.getPlayerList().getPlayers().isEmpty();
		try {
			if (active) {
				Files.writeString(activeFlag(), Long.toString(System.currentTimeMillis()));
			} else {
				Files.deleteIfExists(activeFlag());
			}
		} catch (IOException e) {
			LOGGER.error("[MCHC] Kon active-flag niet bijwerken", e);
		}
	}

	private void broadcastTitle(String deadPlayer) {
		if (server == null) return;
		Component title = Component.literal(titleTemplate.replace("%player%", deadPlayer));
		Component sub = Component.literal(subtitleText);
		int stay = Math.max(1, countdownSeconds * 20);
		ClientboundSetTitlesAnimationPacket anim = new ClientboundSetTitlesAnimationPacket(10, stay, 10);
		ClientboundSetTitleTextPacket titlePkt = new ClientboundSetTitleTextPacket(title);
		ClientboundSetSubtitleTextPacket subPkt = new ClientboundSetSubtitleTextPacket(sub);
		for (ServerPlayer p : server.getPlayerList().getPlayers()) {
			p.connection.send(anim);
			p.connection.send(subPkt);
			p.connection.send(titlePkt);
		}
	}

	private void runCommand(MinecraftServer srv, String cmd) {
		try {
			srv.getCommands().performPrefixedCommand(srv.createCommandSourceStack(), cmd);
		} catch (Exception e) {
			LOGGER.warn("[MCHC] Commando '{}' faalde", cmd, e);
		}
	}

	private Path readyFlag()        { return controlDir.resolve(serverName + ".ready"); }
	private Path partnerReadyFlag() { return controlDir.resolve(partnerName + ".ready"); }
	private Path activeFlag()       { return controlDir.resolve(serverName + ".active"); }
	private Path wakePartnerFlag()  { return controlDir.resolve("wake-" + partnerName + ".flag"); }
	private Path resetNowFlag()     { return controlDir.resolve(serverName + ".reset-now.flag"); }

	private void loadConfig() {
		Path cfg = Paths.get("hardcore.properties");
		Properties p = new Properties();
		if (Files.exists(cfg)) {
			try (var in = Files.newInputStream(cfg)) {
				p.load(in);
			} catch (IOException e) {
				LOGGER.error("[MCHC] Kon hardcore.properties niet lezen, standaardwaarden gebruikt.", e);
			}
		} else {
			LOGGER.warn("[MCHC] Geen hardcore.properties in {}. Standaardwaarden.", cfg.toAbsolutePath());
		}
		serverName = p.getProperty("serverName", serverName).trim();
		partnerName = p.getProperty("partnerName", partnerName).trim();
		controlDir = Paths.get(p.getProperty("controlDir", "../control").trim());
		countdownSeconds = parseInt(p.getProperty("countdownSeconds", "5"), 5);
		partnerPort = parseInt(p.getProperty("partnerPort", "25567"), 25567);
		titleTemplate = p.getProperty("title", titleTemplate);
		subtitleText = p.getProperty("subtitle", subtitleText);
		localTransferHost = p.getProperty("localTransferHost", localTransferHost).trim();
		publicTransferHost = p.getProperty("publicTransferHost", publicTransferHost).trim();
	}

	private static int parseInt(String s, int def) {
		try {
			return Integer.parseInt(s.trim());
		} catch (NumberFormatException e) {
			return def;
		}
	}
}
