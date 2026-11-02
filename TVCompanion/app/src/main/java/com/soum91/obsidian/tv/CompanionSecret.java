package com.soum91.obsidian.tv;

import android.content.Context;

import java.security.SecureRandom;
import java.util.Base64;

final class CompanionSecret {
    private CompanionSecret() { }

    static synchronized String getOrCreate(Context context) {
        android.content.SharedPreferences prefs = context.getSharedPreferences("obsidian_live", Context.MODE_PRIVATE);
        String saved = prefs.getString("device_secret", null);
        if (saved != null) return saved;
        byte[] bytes = new byte[32];
        new SecureRandom().nextBytes(bytes);
        String secret = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
        if (!prefs.edit().putString("device_secret", secret).commit()) {
            throw new IllegalStateException("Could not save pairing secret");
        }
        return secret;
    }
}
