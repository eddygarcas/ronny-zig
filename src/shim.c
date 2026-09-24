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
#include <string.h>

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

typedef struct {
    uint32_t uid;
    char from[RONNY_ADDR_MAX];    /* mailbox@host, lowercased by the caller */
    char subject[RONNY_SUBJ_MAX]; /* still MIME-encoded; decoded in Zig */
} ronny_envelope;

static void copy_bounded(char *dst, size_t cap, const char *src) {
    if (src == NULL) { dst[0] = '\0'; return; }
    size_t n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
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
                if (env != NULL) copy_bounded(entry.subject, sizeof(entry.subject), env->env_subject);
            }
        }

        if (entry.uid != 0) out[count++] = entry;
    }

    mailimap_fetch_list_free(result);
    return count;
}
