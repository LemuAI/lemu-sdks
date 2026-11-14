package com.lemuai.analytics.core;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

import com.lemuai.analytics.LemuContent;
import com.lemuai.analytics.LemuEvent;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.Test;

/** Java callers can pass nulls the Kotlin types forbid; the SDK must not throw. */
public class JavaInteropTest {
    @Test
    @SuppressWarnings("unchecked")
    public void C17_java_nulls_never_throw() throws Exception {
        try (Harness h = new Harness(new FakeIngestServer(), new InMemoryStorage(), new FakeClock(1_794_650_400_000L))) {
            LemuClient lemu = h.client(false, 20, 1000, h.getServer().getUrl(), null, new UrlConnectionTransport(2000, 5000));
            lemu.track(null, null);
            lemu.screen(null, null);
            lemu.identify(null, null);
            lemu.setCampaign(null);
            lemu.deepLinkOpened(null, null);
            lemu.purchase(Double.NaN, null, null, null, null, null, null);

            Map<String, Object> props = new HashMap<>();
            props.put("value", 999);
            props.put(null, "ignored");
            lemu.track(LemuEvent.ADD_TO_CART, props);
            lemu.purchase(10.0, "inr", "o-1", Collections.singletonList(new LemuContent("SKU1")), null, 2, null);
            lemu.flush();

            h.assertAllValid();
            List<Map<String, Object>> sent = h.getServer().delivered();
            assertEquals(3, sent.size());
            Map<String, Object> bare = (Map<String, Object>) sent.get(0).get("properties");
            assertFalse("purchase without value or currency is still sent", bare.containsKey("value"));
            assertEquals(LemuEvent.ADD_TO_CART, sent.get(1).get("event"));
            Map<String, Object> p = (Map<String, Object>) sent.get(2).get("properties");
            assertEquals("INR", p.get("currency"));
            assertEquals(2L, p.get("num_items"));
        }
    }
}
