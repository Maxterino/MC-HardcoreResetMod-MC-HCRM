package nl.mchc.hardcore;

import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.codec.StreamCodec;
import net.minecraft.network.protocol.common.custom.CustomPacketPayload;
import net.minecraft.resources.Identifier;

import java.util.ArrayList;
import java.util.List;

/**
 * Server -> client payload met de speeltijd-statistieken en het aantal doden per speler.
 * Wordt elke seconde door de server naar alle spelers gestuurd; de client-HUD rendert het.
 *
 *  runSeconds   = speeltijd van de HUIDIGE run (huidige wereld), reset bij elke wereld-reset.
 *  totalSeconds = totale speeltijd over alle runs heen (blijft bewaard).
 */
public record MchcStatsPayload(long runSeconds, long totalSeconds, List<Entry> entries)
		implements CustomPacketPayload {

	public record Entry(String name, int deaths) {
	}

	public static final Type<MchcStatsPayload> TYPE =
			new Type<>(Identifier.fromNamespaceAndPath("mchc-hardcore", "stats"));

	public static final StreamCodec<RegistryFriendlyByteBuf, MchcStatsPayload> CODEC = StreamCodec.of(
			(buf, payload) -> {
				buf.writeVarLong(payload.runSeconds);
				buf.writeVarLong(payload.totalSeconds);
				buf.writeVarInt(payload.entries.size());
				for (Entry e : payload.entries) {
					buf.writeUtf(e.name());
					buf.writeVarInt(e.deaths());
				}
			},
			(buf) -> {
				long run = buf.readVarLong();
				long total = buf.readVarLong();
				int n = buf.readVarInt();
				List<Entry> es = new ArrayList<>(n);
				for (int i = 0; i < n; i++) {
					String name = buf.readUtf();
					int deaths = buf.readVarInt();
					es.add(new Entry(name, deaths));
				}
				return new MchcStatsPayload(run, total, es);
			}
	);

	@Override
	public Type<? extends CustomPacketPayload> type() {
		return TYPE;
	}
}
