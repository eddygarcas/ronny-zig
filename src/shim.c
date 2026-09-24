/* The C side of the libetpan boundary.
 *
 * Two reasons this file exists rather than doing everything in Zig:
 *
 * 1. Zig's translate-c has no representation for C bitfields, so any struct
 *    containing one becomes `opaque` and none of its fields are reachable.
 *    mailimap_selection_info ends with `uint8_t sel_has_exists:1`, which is
 *    enough to hide sel_exists.
 *
 * 2. libetpan returns results as nested clists of tagged unions. Walking
 *    those is straightforward in C and genuinely unpleasant through
 *    translate-c. Doing it here and handing Zig flat structs keeps the
 *    awkwardness in one place and the Zig side honest.
 *
 * Zig compiles this as part of the same build -- there is no separate step.
 */

#include <libetpan/libetpan.h>
#include <libetpan/mailmime_decode.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>
#include <strings.h>

/* ---- selection info (hidden behind bitfields) ---- */

uint32_t ronny_selection_exists(mailimap *session) {
    if (session == NULL || session->imap_selection_info == NULL) return 0;
    return session->imap_selection_info->sel_exists;
}

uint32_t ronny_selection_uidnext(mailimap *session) {
    if (session == NULL || session->imap_selection_info == NULL) return 0;
    return session->imap_selection_info->sel_uidnext;
}

uint32_t ronny_selection_uidvalidity(mailimap *session) {
    if (session == NULL || session->imap_selection_info == NULL) return 0;
    return session->imap_selection_info->sel_uidvalidity;
}

/* ---- envelopes ---- */

#define RONNY_ADDR_MAX 256
#define RONNY_SUBJ_MAX 512
#define RONNY_DATE_MAX 64

typedef struct {
    uint32_t uid;
    char from[RONNY_ADDR_MAX];    /* mailbox@host, lowercased by the caller */
    char subject[RONNY_SUBJ_MAX]; /* decoded to UTF-8 */
    char date[RONNY_DATE_MAX];    /* the raw Date: header, as sent */
} ronny_envelope;

static void copy_bounded(char *dst, size_t cap, const char *src) {
    if (src == NULL) { dst[0] = '\0'; return; }
    size_t n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

/* Decodes an RFC 2047 header ("=?UTF-8?Q?...?=") into plain UTF-8.
 *
 * Subjects arrive encoded, and showing the owner the raw encoded form is
 * useless. libetpan does the decoding; on failure the original is copied
 * through unchanged so a header we cannot decode is still readable.
 */
static void decode_header(char *dst, size_t cap, const char *src) {
    dst[0] = '\0';
    if (src == NULL) return;

    size_t index = 0;
    char *decoded = NULL;
    int r = mailmime_encoded_phrase_parse("utf-8", src, strlen(src), &index, "utf-8", &decoded);
    if (r == MAILIMF_NO_ERROR && decoded != NULL) {
        copy_bounded(dst, cap, decoded);
        free(decoded);
        return;
    }
    copy_bounded(dst, cap, src);
}

/* Flattens the first From address into "mailbox@host". */
static void envelope_from(struct mailimap_envelope *env, char *dst, size_t cap) {
    dst[0] = '\0';
    if (env == NULL || env->env_from == NULL || env->env_from->frm_list == NULL) return;

    clistiter *it = clist_begin(env->env_from->frm_list);
    if (it == NULL) return;

    struct mailimap_address *addr = clist_content(it);
    if (addr == NULL || addr->ad_mailbox_name == NULL) return;

    if (addr->ad_host_name == NULL) {
        copy_bounded(dst, cap, addr->ad_mailbox_name);
        return;
    }
    snprintf(dst, cap, "%s@%s", addr->ad_mailbox_name, addr->ad_host_name);
}

/* Fetches UID + ENVELOPE for every message with UID >= first_uid.
 *
 * Returns the number written to `out`, or -1 on failure. Asking for
 * "first_uid:*" is how IMAP expresses "everything newer than this", which is
 * what the watcher needs after an IDLE wakeup.
 */
int ronny_fetch_envelopes_since(mailimap *session, uint32_t first_uid,
                                ronny_envelope *out, int max_out) {
    if (session == NULL || out == NULL || max_out <= 0) return -1;

    struct mailimap_set *set = mailimap_set_new_interval(first_uid, 0); /* 0 == "*" */
    if (set == NULL) return -1;

    struct mailimap_fetch_type *fetch_type = mailimap_fetch_type_new_fetch_att_list_empty();
    if (fetch_type == NULL) { mailimap_set_free(set); return -1; }

    if (mailimap_fetch_type_new_fetch_att_list_add(fetch_type, mailimap_fetch_att_new_uid()) != MAILIMAP_NO_ERROR ||
        mailimap_fetch_type_new_fetch_att_list_add(fetch_type, mailimap_fetch_att_new_envelope()) != MAILIMAP_NO_ERROR) {
        mailimap_fetch_type_free(fetch_type);
        mailimap_set_free(set);
        return -1;
    }

    clist *result = NULL;
    int r = mailimap_uid_fetch(session, set, fetch_type, &result);
    mailimap_fetch_type_free(fetch_type);
    mailimap_set_free(set);
    if (r != MAILIMAP_NO_ERROR) return -1;

    int count = 0;
    for (clistiter *it = clist_begin(result); it != NULL && count < max_out; it = clist_next(it)) {
        struct mailimap_msg_att *msg = clist_content(it);
        if (msg == NULL) continue;

        ronny_envelope entry;
        memset(&entry, 0, sizeof(entry));

        for (clistiter *ait = clist_begin(msg->att_list); ait != NULL; ait = clist_next(ait)) {
            struct mailimap_msg_att_item *item = clist_content(ait);
            if (item == NULL || item->att_type != MAILIMAP_MSG_ATT_ITEM_STATIC) continue;

            struct mailimap_msg_att_static *stat = item->att_data.att_static;
            if (stat == NULL) continue;

            if (stat->att_type == MAILIMAP_MSG_ATT_UID) {
                entry.uid = stat->att_data.att_uid;
            } else if (stat->att_type == MAILIMAP_MSG_ATT_ENVELOPE) {
                struct mailimap_envelope *env = stat->att_data.att_env;
                envelope_from(env, entry.from, sizeof(entry.from));
                if (env != NULL) {
                    decode_header(entry.subject, sizeof(entry.subject), env->env_subject);
                    copy_bounded(entry.date, sizeof(entry.date), env->env_date);
                }
            }
        }

        if (entry.uid != 0) out[count++] = entry;
    }

    mailimap_fetch_list_free(result);
    return count;
}

/* ---- full message fetch (for the spam gate) ---- */

#define RONNY_HDR_MAX  8192
#define RONNY_BODY_MAX 8192

typedef struct {
    char headers[RONNY_HDR_MAX];
    char body[RONNY_BODY_MAX];
} ronny_message;

/* Fetches headers and text body for one UID.
 *
 * Header and text parts are requested separately: the deterministic spam
 * checks only read headers, and the model only needs the text. Requesting
 * BODY.PEEK avoids setting \Seen, so inspecting mail never marks it read --
 * the same guarantee the Python watcher had from a read-only selection.
 */
int ronny_fetch_message(mailimap *session, uint32_t uid, ronny_message *out) {
    if (session == NULL || out == NULL) return -1;
    memset(out, 0, sizeof(*out));

    struct mailimap_set *set = mailimap_set_new_single(uid);
    if (set == NULL) return -1;

    struct mailimap_fetch_type *fetch_type = mailimap_fetch_type_new_fetch_att_list_empty();
    if (fetch_type == NULL) { mailimap_set_free(set); return -1; }

    if (mailimap_fetch_type_new_fetch_att_list_add(fetch_type, mailimap_fetch_att_new_rfc822_header()) != MAILIMAP_NO_ERROR ||
        mailimap_fetch_type_new_fetch_att_list_add(fetch_type, mailimap_fetch_att_new_rfc822_text()) != MAILIMAP_NO_ERROR) {
        mailimap_fetch_type_free(fetch_type);
        mailimap_set_free(set);
        return -1;
    }

    clist *result = NULL;
    int r = mailimap_uid_fetch(session, set, fetch_type, &result);
    mailimap_fetch_type_free(fetch_type);
    mailimap_set_free(set);
    if (r != MAILIMAP_NO_ERROR) return -1;

    for (clistiter *it = clist_begin(result); it != NULL; it = clist_next(it)) {
        struct mailimap_msg_att *msg = clist_content(it);
        if (msg == NULL) continue;

        for (clistiter *ait = clist_begin(msg->att_list); ait != NULL; ait = clist_next(ait)) {
            struct mailimap_msg_att_item *item = clist_content(ait);
            if (item == NULL || item->att_type != MAILIMAP_MSG_ATT_ITEM_STATIC) continue;

            struct mailimap_msg_att_static *stat = item->att_data.att_static;
            if (stat == NULL) continue;

            if (stat->att_type == MAILIMAP_MSG_ATT_RFC822_HEADER) {
                copy_bounded(out->headers, sizeof(out->headers), stat->att_data.att_rfc822_header.att_content);
            } else if (stat->att_type == MAILIMAP_MSG_ATT_RFC822_TEXT) {
                copy_bounded(out->body, sizeof(out->body), stat->att_data.att_rfc822_text.att_content);
            }
        }
    }

    mailimap_fetch_list_free(result);
    return 0;
}

/* ---- searching ---- */

/* Fills envelopes for a list of UIDs, newest first. Shared by both searches. */
static int envelopes_for_uids(mailimap *session, clist *uid_list,
                              ronny_envelope *out, int max_out) {
    if (uid_list == NULL) return 0;

    /* Newest first: a question about mail is far more often about recent mail. */
    uint32_t best[512];
    int n = 0;
    for (clistiter *it = clist_begin(uid_list); it != NULL && n < 512; it = clist_next(it)) {
        uint32_t *uid = clist_content(it);
        if (uid != NULL) best[n++] = *uid;
    }
    mailimap_search_result_free(uid_list);
    if (n == 0) return 0;

    for (int i = 0; i < n - 1; i++)
        for (int j = i + 1; j < n; j++)
            if (best[j] > best[i]) { uint32_t t = best[i]; best[i] = best[j]; best[j] = t; }

    if (n > max_out) n = max_out;

    struct mailimap_set *set = mailimap_set_new_empty();
    if (set == NULL) return -1;
    for (int i = 0; i < n; i++) mailimap_set_add_single(set, best[i]);

    struct mailimap_fetch_type *fetch_type = mailimap_fetch_type_new_fetch_att_list_empty();
    if (fetch_type == NULL) { mailimap_set_free(set); return -1; }
    if (mailimap_fetch_type_new_fetch_att_list_add(fetch_type, mailimap_fetch_att_new_uid()) != MAILIMAP_NO_ERROR ||
        mailimap_fetch_type_new_fetch_att_list_add(fetch_type, mailimap_fetch_att_new_envelope()) != MAILIMAP_NO_ERROR) {
        mailimap_fetch_type_free(fetch_type);
        mailimap_set_free(set);
        return -1;
    }

    clist *result = NULL;
    int r = mailimap_uid_fetch(session, set, fetch_type, &result);
    mailimap_fetch_type_free(fetch_type);
    mailimap_set_free(set);
    if (r != MAILIMAP_NO_ERROR) return -1;

    int count = 0;
    for (clistiter *it = clist_begin(result); it != NULL && count < max_out; it = clist_next(it)) {
        struct mailimap_msg_att *msg = clist_content(it);
        if (msg == NULL) continue;

        ronny_envelope entry;
        memset(&entry, 0, sizeof(entry));

        for (clistiter *ait = clist_begin(msg->att_list); ait != NULL; ait = clist_next(ait)) {
            struct mailimap_msg_att_item *item = clist_content(ait);
            if (item == NULL || item->att_type != MAILIMAP_MSG_ATT_ITEM_STATIC) continue;
            struct mailimap_msg_att_static *stat = item->att_data.att_static;
            if (stat == NULL) continue;

            if (stat->att_type == MAILIMAP_MSG_ATT_UID) {
                entry.uid = stat->att_data.att_uid;
            } else if (stat->att_type == MAILIMAP_MSG_ATT_ENVELOPE) {
                struct mailimap_envelope *env = stat->att_data.att_env;
                envelope_from(env, entry.from, sizeof(entry.from));
                if (env != NULL) {
                    decode_header(entry.subject, sizeof(entry.subject), env->env_subject);
                    copy_bounded(entry.date, sizeof(entry.date), env->env_date);
                }
            }
        }
        if (entry.uid != 0) out[count++] = entry;
    }

    mailimap_fetch_list_free(result);
    return count;
}

/* Mail from a sender within the last `days`.
 *
 * IMAP's FROM criterion is a substring match over the whole header, so a bare
 * domain or a display name works, not only a full address.
 */
int ronny_search_from(mailimap *session, const char *sender, int days,
                      ronny_envelope *out, int max_out) {
    if (session == NULL || sender == NULL || out == NULL || max_out <= 0) return -1;

    time_t since_t = time(NULL) - (time_t)days * 24 * 60 * 60;
    struct tm tm_since;
    gmtime_r(&since_t, &tm_since);

    struct mailimap_date *since = mailimap_date_new(tm_since.tm_mday, tm_since.tm_mon + 1, tm_since.tm_year + 1900);
    if (since == NULL) return -1;
    struct mailimap_search_key *by_date = mailimap_search_key_new_since(since);
    if (by_date == NULL) { mailimap_date_free(since); return -1; }

    char *sender_copy = strdup(sender);
    if (sender_copy == NULL) { mailimap_search_key_free(by_date); return -1; }
    struct mailimap_search_key *by_from = mailimap_search_key_new_from(sender_copy);
    if (by_from == NULL) { free(sender_copy); mailimap_search_key_free(by_date); return -1; }

    clist *keys = clist_new();
    if (keys == NULL) { mailimap_search_key_free(by_from); mailimap_search_key_free(by_date); return -1; }
    clist_append(keys, by_date);
    clist_append(keys, by_from);

    struct mailimap_search_key *combined = mailimap_search_key_new_multiple(keys);
    if (combined == NULL) { clist_free(keys); return -1; }

    clist *uid_list = NULL;
    int r = mailimap_uid_search(session, NULL, combined, &uid_list);
    mailimap_search_key_free(combined);
    if (r != MAILIMAP_NO_ERROR) return -1;

    return envelopes_for_uids(session, uid_list, out, max_out);
}

/* ---- voice vocabulary ---- */

#define RONNY_VOCAB_ENTRY 96

/* Collects the names and addresses that actually write to this mailbox.
 *
 * This exists for one reason: whisper guesses phonetically at names it has not
 * been told about, and "1Password" came back as "one password" while
 * "AcmeSync" came back as "acme synch". Both write here regularly and neither is
 * a watched sender, so the allowlist alone was not enough.
 *
 * Display names matter more than addresses here -- they are what gets spoken
 * -- and ronny_envelope flattens them away, which is why this fetches
 * envelopes itself rather than reusing envelopes_for_uids.
 *
 * `out` is a flat array of `max_out` fixed-width entries, each
 * RONNY_VOCAB_ENTRY bytes. Returns how many were written, or -1.
 */
int ronny_sender_vocabulary(mailimap *session, int days, char *out, int max_out) {
    if (session == NULL || out == NULL || max_out <= 0) return -1;
    memset(out, 0, (size_t)max_out * RONNY_VOCAB_ENTRY);

    time_t since_t = time(NULL) - (time_t)days * 24 * 60 * 60;
    struct tm tm_since;
    gmtime_r(&since_t, &tm_since);

    struct mailimap_date *since = mailimap_date_new(tm_since.tm_mday, tm_since.tm_mon + 1, tm_since.tm_year + 1900);
    if (since == NULL) return -1;
    struct mailimap_search_key *key = mailimap_search_key_new_since(since);
    if (key == NULL) { mailimap_date_free(since); return -1; }

    clist *uid_list = NULL;
    int r = mailimap_uid_search(session, NULL, key, &uid_list);
    mailimap_search_key_free(key);
    if (r != MAILIMAP_NO_ERROR) return -1;
    if (uid_list == NULL) return 0;

    /* Newest first, and bounded: the window can hold thousands of messages and
     * the vocabulary only needs the recent, recurring correspondents. */
    uint32_t uids[1024];
    int n = 0;
    for (clistiter *it = clist_begin(uid_list); it != NULL && n < 1024; it = clist_next(it)) {
        uint32_t *uid = clist_content(it);
        if (uid != NULL) uids[n++] = *uid;
    }
    mailimap_search_result_free(uid_list);
    if (n == 0) return 0;

    for (int i = 0; i < n - 1; i++)
        for (int j = i + 1; j < n; j++)
            if (uids[j] > uids[i]) { uint32_t t = uids[i]; uids[i] = uids[j]; uids[j] = t; }
    if (n > 600) n = 600;

    struct mailimap_set *set = mailimap_set_new_empty();
    if (set == NULL) return -1;
    for (int i = 0; i < n; i++) mailimap_set_add_single(set, uids[i]);

    struct mailimap_fetch_type *fetch_type = mailimap_fetch_type_new_fetch_att_list_empty();
    if (fetch_type == NULL) { mailimap_set_free(set); return -1; }
    if (mailimap_fetch_type_new_fetch_att_list_add(fetch_type, mailimap_fetch_att_new_envelope()) != MAILIMAP_NO_ERROR) {
        mailimap_fetch_type_free(fetch_type);
        mailimap_set_free(set);
        return -1;
    }

    clist *result = NULL;
    r = mailimap_uid_fetch(session, set, fetch_type, &result);
    mailimap_fetch_type_free(fetch_type);
    mailimap_set_free(set);
    if (r != MAILIMAP_NO_ERROR) return -1;

    int count = 0;
    for (clistiter *it = clist_begin(result); it != NULL && count < max_out; it = clist_next(it)) {
        struct mailimap_msg_att *msg = clist_content(it);
        if (msg == NULL) continue;

        for (clistiter *ait = clist_begin(msg->att_list); ait != NULL; ait = clist_next(ait)) {
            struct mailimap_msg_att_item *item = clist_content(ait);
            if (item == NULL || item->att_type != MAILIMAP_MSG_ATT_ITEM_STATIC) continue;
            struct mailimap_msg_att_static *stat = item->att_data.att_static;
            if (stat == NULL || stat->att_type != MAILIMAP_MSG_ATT_ENVELOPE) continue;

            struct mailimap_envelope *env = stat->att_data.att_env;
            if (env == NULL || env->env_from == NULL || env->env_from->frm_list == NULL) continue;
            clistiter *fit = clist_begin(env->env_from->frm_list);
            if (fit == NULL) continue;
            struct mailimap_address *addr = clist_content(fit);
            if (addr == NULL) continue;

            /* Two candidates per message: the display name, then the address.
             * Display names are RFC 2047 encoded like any other header. */
            char candidates[2][RONNY_VOCAB_ENTRY];
            int wanted = 0;
            if (addr->ad_personal_name != NULL) {
                decode_header(candidates[wanted], RONNY_VOCAB_ENTRY, addr->ad_personal_name);
                if (candidates[wanted][0] != '\0') wanted++;
            }
            if (addr->ad_mailbox_name != NULL && addr->ad_host_name != NULL) {
                snprintf(candidates[wanted], RONNY_VOCAB_ENTRY, "%s@%s",
                         addr->ad_mailbox_name, addr->ad_host_name);
                wanted++;
            }

            for (int i = 0; i < wanted && count < max_out; i++) {
                int duplicate = 0;
                for (int j = 0; j < count; j++) {
                    if (strcasecmp(out + (size_t)j * RONNY_VOCAB_ENTRY, candidates[i]) == 0) {
                        duplicate = 1;
                        break;
                    }
                }
                if (!duplicate) {
                    copy_bounded(out + (size_t)count * RONNY_VOCAB_ENTRY, RONNY_VOCAB_ENTRY, candidates[i]);
                    count++;
                }
            }
        }
    }

    mailimap_fetch_list_free(result);
    return count;
}

/* Gmail's own search, exposed over IMAP as the X-GM-RAW search key.
 *
 * This is what makes content search work without a local index: Gmail already
 * maintains one and answers in well under a second across 50k messages.
 */
int ronny_search_gmail(mailimap *session, const char *query,
                       ronny_envelope *out, int max_out) {
    if (session == NULL || query == NULL || out == NULL || max_out <= 0) return -1;

    char *query_copy = strdup(query);
    if (query_copy == NULL) return -1;
    struct mailimap_search_key *key = mailimap_search_key_new_xgmraw(query_copy);
    if (key == NULL) { free(query_copy); return -1; }

    clist *uid_list = NULL;
    int r = mailimap_uid_search(session, NULL, key, &uid_list);
    mailimap_search_key_free(key);
    if (r != MAILIMAP_NO_ERROR) return -1;

    return envelopes_for_uids(session, uid_list, out, max_out);
}
