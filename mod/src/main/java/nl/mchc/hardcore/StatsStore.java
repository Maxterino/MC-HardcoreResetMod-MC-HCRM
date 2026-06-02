package nl.mchc.hardcore;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;

/**
 * Shared stats, stored in control/stats.properties.
 * Kept across the switch between the two servers.
 *
 *  totalSeconds = total playtime across all runs (always keeps counting up).
 *  runSeconds   = playtime of the current run; set to 0 on a world reset.
 *  deaths       = death count per player (insertion order = player 1, 2, ...).
 */
public class StatsStore {
	private static final Logger LOGGER = LoggerFactory.getLogger("mchc-hardcore");

	private final Path file;
	private long totalSeconds = 0L;
	private long runSeconds = 0L;
	private final Map<String, Integer> deaths = new LinkedHashMap<>();

	public StatsStore(Path controlDir) {
		this.file = controlDir.resolve("stats.properties");
	}

	public synchronized void load() {
		if (!Files.exists(file)) return;
		Properties p = new Properties();
		try (var in = Files.newInputStream(file)) {
			p.load(in);
		} catch (IOException e) {
			LOGGER.error("[MCHC] Could not read stats.properties", e);
			return;
		}
		// "playtimeSeconds" is the old name; still supported as a fallback for total.
		totalSeconds = parseLong(p.getProperty("totalSeconds", p.getProperty("playtimeSeconds", "0")));
		runSeconds = parseLong(p.getProperty("runSeconds", "0"));
		deaths.clear();
		String order = p.getProperty("order", "");
		if (!order.isBlank()) {
			for (String name : order.split("\t")) {
				if (name.isBlank()) continue;
				deaths.put(name, parseInt(p.getProperty("deaths." + name, "0")));
			}
		}
		for (String key : p.stringPropertyNames()) {
			if (key.startsWith("deaths.")) {
				String name = key.substring("deaths.".length());
				deaths.putIfAbsent(name, parseInt(p.getProperty(key, "0")));
			}
		}
	}

	private static int parseInt(String s) {
		try {
			return Integer.parseInt(s.trim());
		} catch (NumberFormatException e) {
			return 0;
		}
	}

	private static long parseLong(String s) {
		try {
			return Long.parseLong(s.trim());
		} catch (NumberFormatException e) {
			return 0L;
		}
	}

	public synchronized void save() {
		Properties p = new Properties();
		p.setProperty("totalSeconds", Long.toString(totalSeconds));
		p.setProperty("runSeconds", Long.toString(runSeconds));
		p.setProperty("order", String.join("\t", deaths.keySet()));
		for (Map.Entry<String, Integer> e : deaths.entrySet()) {
			p.setProperty("deaths." + e.getKey(), Integer.toString(e.getValue()));
		}
		try {
			Files.createDirectories(file.getParent());
			try (var out = Files.newOutputStream(file)) {
				p.store(out, "MCHC Hardcore stats");
			}
		} catch (IOException e) {
			LOGGER.error("[MCHC] Could not write stats.properties", e);
		}
	}

	public synchronized void addSecond() {
		totalSeconds++;
		runSeconds++;
	}

	/** Reset only the run timer (on a new world). Total and deaths stay. */
	public synchronized void resetRun() {
		runSeconds = 0L;
	}

	public synchronized void recordDeath(String player) {
		deaths.merge(player, 1, Integer::sum);
	}

	/** Ensures a player is in the list (so they show with 0 deaths in the HUD). */
	public synchronized void ensurePlayer(String player) {
		deaths.putIfAbsent(player, 0);
	}

	public synchronized long totalSeconds() {
		return totalSeconds;
	}

	public synchronized long runSeconds() {
		return runSeconds;
	}

	public synchronized List<MchcStatsPayload.Entry> entries() {
		List<MchcStatsPayload.Entry> list = new ArrayList<>(deaths.size());
		for (Map.Entry<String, Integer> e : deaths.entrySet()) {
			list.add(new MchcStatsPayload.Entry(e.getKey(), e.getValue()));
		}
		return list;
	}
}
