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
 * Gedeelde statistieken (speeltijd + doden per speler), opgeslagen in control/stats.properties.
 * Blijft bewaard over wereld-resets én over de wissel tussen de twee servers heen.
 */
public class StatsStore {
	private static final Logger LOGGER = LoggerFactory.getLogger("mchc-hardcore");

	private final Path file;
	private long playtimeSeconds = 0L;
	// behoudt invoegvolgorde -> speler 1, speler 2, ...
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
			LOGGER.error("[MCHC] Kon stats.properties niet lezen", e);
			return;
		}
		try {
			playtimeSeconds = Long.parseLong(p.getProperty("playtimeSeconds", "0").trim());
		} catch (NumberFormatException ignored) {
			playtimeSeconds = 0L;
		}
		deaths.clear();
		// herstel volgorde via deaths.order, anders gewoon de keys
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

	public synchronized void save() {
		Properties p = new Properties();
		p.setProperty("playtimeSeconds", Long.toString(playtimeSeconds));
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
			LOGGER.error("[MCHC] Kon stats.properties niet schrijven", e);
		}
	}

	public synchronized void addSecond() {
		playtimeSeconds++;
	}

	public synchronized void recordDeath(String player) {
		deaths.merge(player, 1, Integer::sum);
	}

	/** Zorgt dat een speler in de lijst staat (zodat hij met 0 doden zichtbaar is in de HUD). */
	public synchronized void ensurePlayer(String player) {
		deaths.putIfAbsent(player, 0);
	}

	public synchronized long playtimeSeconds() {
		return playtimeSeconds;
	}

	public synchronized List<MchcStatsPayload.Entry> entries() {
		List<MchcStatsPayload.Entry> list = new ArrayList<>(deaths.size());
		for (Map.Entry<String, Integer> e : deaths.entrySet()) {
			list.add(new MchcStatsPayload.Entry(e.getKey(), e.getValue()));
		}
		return list;
	}
}
