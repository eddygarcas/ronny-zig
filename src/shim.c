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
#include <stddef.h>

/* ---- local time ---- */

/* Minutes since local midnight.
 *
 * Not libetpan, but here for the same reason as the rest of this file: Zig's
 * standard library has no timezone database, so "is it currently quiet
 * hours?" cannot be answered from std alone. libc already knows, via TZ and
 * /etc/localtime, and asking it is one line.
 */
/* Today's date in local time, as year/month/day.
 *
 * Same reason as ronny_local_minutes: Zig's standard library has no timezone
 * database, and "yesterday" is a question about the owner's calendar, not
 * UTC's. libc already knows, via TZ and /etc/localtime. */
void ronny_today(int *year, int *month, int *day) {
    time_t now = time(NULL);
    struct tm local;
    if (localtime_r(&now, &local) == NULL) {
        *year = 0; *month = 1; *day = 1;
        return;
    }
    *year = local.tm_year + 1900;
    *month = local.tm_mon + 1;
    *day = local.tm_mday;
}

int ronny_local_minutes(void) {
    time_t now = time(NULL);
    struct tm local;
    if (localtime_r(&now, &local) == NULL) return -1;
    return local.tm_hour * 60 + local.tm_min;
}

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

#define RONNY_HDR_MAX    8192
#define RONNY_BODY_MAX   8192
#define RONNY_ATTACH_MAX 16
#define RONNY_FNAME_MAX  200
#define RONNY_CTYPE_MAX  100

typedef struct {
    char filename[RONNY_FNAME_MAX];   /* RFC 2047 decoded, or "part-N" */
    char mime_type[RONNY_CTYPE_MAX];  /* "application/pdf" */
    uint32_t size;                    /* approximate DECODED bytes */
    uint32_t index;                   /* ordinal among single parts, for fetching */
    uint8_t is_inline;                /* Content-Disposition: inline */
} ronny_attachment;

typedef struct {
    char headers[RONNY_HDR_MAX];
    char body[RONNY_BODY_MAX];
    int32_t attachment_count;
    ronny_attachment attachments[RONNY_ATTACH_MAX];
} ronny_message;

/* Is this MIME part text, and of which subtype? */
static int part_is_text(struct mailmime *mime, const char *subtype) {
    struct mailmime_content *content = mime->mm_content_type;
    if (content == NULL || content->ct_type == NULL) {
        /* No Content-Type at all means text/plain by RFC 2045. */
        return strcasecmp(subtype, "plain") == 0;
    }
    if (content->ct_type->tp_type != MAILMIME_TYPE_DISCRETE_TYPE) return 0;
    if (content->ct_type->tp_data.tp_discrete_type->dt_type != MAILMIME_DISCRETE_TYPE_TEXT) return 0;
    return content->ct_subtype != NULL && strcasecmp(content->ct_subtype, subtype) == 0;
}

/* Appends one text part's decoded content to `dst`.
 *
 * mailmime_part_parse is what undoes quoted-printable and base64. Without it
 * the model reads "We=E2=80=99ll" instead of "We'll", which is exactly the
 * kind of thing that makes a ranker decide nothing matched.
 */
static int append_decoded(struct mailmime *mime, char *dst, size_t cap) {
    struct mailmime_data *data = mime->mm_data.mm_single;
    if (data == NULL || data->dt_type != MAILMIME_DATA_TEXT) return 0;

    size_t index = 0;
    char *decoded = NULL;
    size_t decoded_len = 0;
    int r = mailmime_part_parse(data->dt_data.dt_text.dt_data,
                                data->dt_data.dt_text.dt_length,
                                &index, data->dt_encoding, &decoded, &decoded_len);
    if (r != MAILIMF_NO_ERROR || decoded == NULL) return 0;

    size_t used = strlen(dst);
    size_t room = cap - used - 1;
    size_t n = decoded_len < room ? decoded_len : room;
    memcpy(dst + used, decoded, n);
    dst[used + n] = '\0';
    mmap_string_unref(decoded);
    return n > 0;
}

/* ---- attachment parts ---- */

/* The filename a part declares, from Content-Disposition first and the
 * Content-Type `name` parameter as a fallback. Both arrive RFC 2047 encoded
 * as often as not, so both go through decode_header. */
static void part_filename(struct mailmime *mime, char *dst, size_t cap) {
    dst[0] = '\0';

    if (mime->mm_mime_fields != NULL) {
        for (clistiter *it = clist_begin(mime->mm_mime_fields->fld_list); it != NULL; it = clist_next(it)) {
            struct mailmime_field *field = clist_content(it);
            if (field == NULL || field->fld_type != MAILMIME_FIELD_DISPOSITION) continue;
            struct mailmime_disposition *disposition = field->fld_data.fld_disposition;
            if (disposition == NULL || disposition->dsp_parms == NULL) continue;
            for (clistiter *p = clist_begin(disposition->dsp_parms); p != NULL; p = clist_next(p)) {
                struct mailmime_disposition_parm *parm = clist_content(p);
                if (parm != NULL && parm->pa_type == MAILMIME_DISPOSITION_PARM_FILENAME) {
                    decode_header(dst, cap, parm->pa_data.pa_filename);
                    return;
                }
            }
        }
    }

    struct mailmime_content *content = mime->mm_content_type;
    if (content != NULL && content->ct_parameters != NULL) {
        for (clistiter *p = clist_begin(content->ct_parameters); p != NULL; p = clist_next(p)) {
            struct mailmime_parameter *parm = clist_content(p);
            if (parm != NULL && parm->pa_name != NULL && strcasecmp(parm->pa_name, "name") == 0) {
                decode_header(dst, cap, parm->pa_value);
                return;
            }
        }
    }
}

static int part_is_inline(struct mailmime *mime) {
    if (mime->mm_mime_fields == NULL) return 0;
    for (clistiter *it = clist_begin(mime->mm_mime_fields->fld_list); it != NULL; it = clist_next(it)) {
        struct mailmime_field *field = clist_content(it);
        if (field == NULL || field->fld_type != MAILMIME_FIELD_DISPOSITION) continue;
        struct mailmime_disposition *disposition = field->fld_data.fld_disposition;
        if (disposition != NULL && disposition->dsp_type != NULL &&
            disposition->dsp_type->dsp_type == MAILMIME_DISPOSITION_TYPE_INLINE) {
            return 1;
        }
    }
    return 0;
}

/* Reassembles "type/subtype" for Telegram, which wants a real content type. */
static void part_content_type(struct mailmime *mime, char *dst, size_t cap) {
    struct mailmime_content *content = mime->mm_content_type;
    if (content == NULL || content->ct_type == NULL) {
        copy_bounded(dst, cap, "application/octet-stream");
        return;
    }

    const char *type = "application";
    if (content->ct_type->tp_type == MAILMIME_TYPE_DISCRETE_TYPE) {
        struct mailmime_discrete_type *discrete = content->ct_type->tp_data.tp_discrete_type;
        switch (discrete->dt_type) {
        case MAILMIME_DISCRETE_TYPE_TEXT:        type = "text"; break;
        case MAILMIME_DISCRETE_TYPE_IMAGE:       type = "image"; break;
        case MAILMIME_DISCRETE_TYPE_AUDIO:       type = "audio"; break;
        case MAILMIME_DISCRETE_TYPE_VIDEO:       type = "video"; break;
        case MAILMIME_DISCRETE_TYPE_APPLICATION: type = "application"; break;
        case MAILMIME_DISCRETE_TYPE_EXTENSION:
            if (discrete->dt_extension != NULL) type = discrete->dt_extension;
            break;
        default: break;
        }
    } else if (content->ct_type->tp_type == MAILMIME_TYPE_COMPOSITE_TYPE) {
        type = "multipart";
    }
    snprintf(dst, cap, "%s/%s", type,
             content->ct_subtype != NULL ? content->ct_subtype : "octet-stream");
}

/* An attachment is a part that names a file, or any non-text part.
 *
 * The body itself is text/* with no filename, so it falls out naturally.
 * Inline images -- signature logos and the like -- do match, which is honest:
 * they really are attached. They are flagged so the caller can rank them
 * below the file someone actually meant to send. */
static int part_is_attachment(struct mailmime *mime) {
    char filename[RONNY_FNAME_MAX];
    part_filename(mime, filename, sizeof(filename));
    if (filename[0] != '\0') return 1;

    struct mailmime_content *content = mime->mm_content_type;
    if (content == NULL || content->ct_type == NULL) return 0;
    if (content->ct_type->tp_type != MAILMIME_TYPE_DISCRETE_TYPE) return 0;
    return content->ct_type->tp_data.tp_discrete_type->dt_type != MAILMIME_DISCRETE_TYPE_TEXT;
}

/* Encoded length adjusted for the transfer encoding. Approximate on purpose:
 * it is for showing the owner "invoice.pdf (~240 KB)" before they decide to
 * download it, not for allocating anything. */
static uint32_t part_decoded_size(struct mailmime *mime) {
    struct mailmime_data *data = mime->mm_data.mm_single;
    if (data == NULL || data->dt_type != MAILMIME_DATA_TEXT) return 0;
    size_t n = data->dt_data.dt_text.dt_length;
    if (data->dt_encoding == MAILMIME_MECHANISM_BASE64) n = n / 4 * 3;
    return (uint32_t)n;
}

/* Collects attachment metadata, numbering every single part in depth-first
 * order so `index` can address one later without keeping the message around.
 * Both walks must agree on that order, which is why they share this shape. */
static void collect_attachments(struct mailmime *mime, ronny_message *out, int *ordinal) {
    if (mime == NULL) return;

    switch (mime->mm_type) {
    case MAILMIME_SINGLE: {
        int index = (*ordinal)++;
        if (!part_is_attachment(mime)) return;
        if (out->attachment_count >= RONNY_ATTACH_MAX) return;

        ronny_attachment *entry = &out->attachments[out->attachment_count];
        memset(entry, 0, sizeof(*entry));
        part_filename(mime, entry->filename, sizeof(entry->filename));
        part_content_type(mime, entry->mime_type, sizeof(entry->mime_type));
        entry->index = (uint32_t)index;
        entry->is_inline = part_is_inline(mime) ? 1 : 0;
        entry->size = part_decoded_size(mime);
        if (entry->filename[0] == '\0') {
            snprintf(entry->filename, sizeof(entry->filename), "part-%d", index);
        }
        out->attachment_count++;
        break;
    }
    case MAILMIME_MESSAGE:
        collect_attachments(mime->mm_data.mm_message.mm_msg_mime, out, ordinal);
        break;
    case MAILMIME_MULTIPLE:
        for (clistiter *it = clist_begin(mime->mm_data.mm_multipart.mm_mp_list);
             it != NULL; it = clist_next(it)) {
            collect_attachments(clist_content(it), out, ordinal);
        }
        break;
    default:
        break;
    }
}

/* Finds the single part numbered `wanted` and decodes it into `out`.
 * Returns the byte count, or -1. Must walk identically to collect_attachments. */
static long decode_part(struct mailmime *mime, uint32_t wanted, int *ordinal,
                        char *out, size_t cap) {
    if (mime == NULL) return -1;

    switch (mime->mm_type) {
    case MAILMIME_SINGLE: {
        int index = (*ordinal)++;
        if ((uint32_t)index != wanted) return -1;

        struct mailmime_data *data = mime->mm_data.mm_single;
        if (data == NULL || data->dt_type != MAILMIME_DATA_TEXT) return -1;

        size_t position = 0;
        char *decoded = NULL;
        size_t decoded_len = 0;
        int r = mailmime_part_parse(data->dt_data.dt_text.dt_data,
                                    data->dt_data.dt_text.dt_length,
                                    &position, data->dt_encoding, &decoded, &decoded_len);
        if (r != MAILIMF_NO_ERROR || decoded == NULL) return -1;
        if (decoded_len > cap) { mmap_string_unref(decoded); return -2; } /* caller's buffer too small */

        memcpy(out, decoded, decoded_len);
        mmap_string_unref(decoded);
        return (long)decoded_len;
    }
    case MAILMIME_MESSAGE:
        return decode_part(mime->mm_data.mm_message.mm_msg_mime, wanted, ordinal, out, cap);
    case MAILMIME_MULTIPLE:
        for (clistiter *it = clist_begin(mime->mm_data.mm_multipart.mm_mp_list);
             it != NULL; it = clist_next(it)) {
            long n = decode_part(clist_content(it), wanted, ordinal, out, cap);
            if (n != -1) return n;
        }
        return -1;
    default:
        return -1;
    }
}

/* Walks the MIME tree for readable text, preferring `subtype`.
 *
 * Depth-first and stops at the first match: alternative parts carry the same
 * content twice, so taking both would just feed the model duplicates.
 */
static int extract_text(struct mailmime *mime, const char *subtype, char *dst, size_t cap) {
    if (mime == NULL) return 0;

    switch (mime->mm_type) {
    case MAILMIME_SINGLE:
        return part_is_text(mime, subtype) ? append_decoded(mime, dst, cap) : 0;
    case MAILMIME_MESSAGE:
        return extract_text(mime->mm_data.mm_message.mm_msg_mime, subtype, dst, cap);
    case MAILMIME_MULTIPLE:
        for (clistiter *it = clist_begin(mime->mm_data.mm_multipart.mm_mp_list);
             it != NULL; it = clist_next(it)) {
            if (extract_text(clist_content(it), subtype, dst, cap)) return 1;
        }
        return 0;
    default:
        return 0;
    }
}

/* Fetches headers and readable body text for one UID.
 *
 * The whole message comes down in one BODY.PEEK[] and is split here: the raw
 * header block for the deterministic spam checks, and the text/plain part --
 * MIME-walked and transfer-decoded -- for anything a model reads.
 *
 * Handing the model RFC822.TEXT instead, as this first did, is a trap: for
 * multipart mail its first few hundred bytes are boundary markers and
 * Content-Type lines, so a 400-character snippet is mostly MIME boilerplate
 * and the actual sentences never arrive.
 *
 * BODY.PEEK avoids setting \Seen, so inspecting mail never marks it read --
 * the same guarantee the Python watcher had from a read-only selection.
 */
int ronny_fetch_message(mailimap *session, uint32_t uid, ronny_message *out) {
    if (session == NULL || out == NULL) return -1;
    memset(out, 0, sizeof(*out));

    struct mailimap_set *set = mailimap_set_new_single(uid);
    if (set == NULL) return -1;

    struct mailimap_section *section = mailimap_section_new(NULL); /* BODY[] -- everything */
    if (section == NULL) { mailimap_set_free(set); return -1; }

    struct mailimap_fetch_att *att = mailimap_fetch_att_new_body_peek_section(section);
    if (att == NULL) { mailimap_section_free(section); mailimap_set_free(set); return -1; }

    struct mailimap_fetch_type *fetch_type = mailimap_fetch_type_new_fetch_att(att);
    if (fetch_type == NULL) { mailimap_fetch_att_free(att); mailimap_set_free(set); return -1; }

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
            if (stat == NULL || stat->att_type != MAILIMAP_MSG_ATT_BODY_SECTION) continue;

            const char *raw = stat->att_data.att_body_section->sec_body_part;
            size_t raw_len = stat->att_data.att_body_section->sec_length;
            if (raw == NULL || raw_len == 0) continue;

            /* Headers are everything up to the first blank line. */
            size_t header_len = raw_len;
            for (size_t i = 0; i + 1 < raw_len; i++) {
                if (raw[i] == '\n' && (raw[i + 1] == '\n' || (raw[i + 1] == '\r' && i + 2 < raw_len && raw[i + 2] == '\n'))) {
                    header_len = i + 1;
                    break;
                }
            }
            size_t n = header_len < sizeof(out->headers) - 1 ? header_len : sizeof(out->headers) - 1;
            memcpy(out->headers, raw, n);
            out->headers[n] = '\0';

            size_t index = 0;
            struct mailmime *mime = NULL;
            if (mailmime_parse(raw, raw_len, &index, &mime) == MAILIMF_NO_ERROR && mime != NULL) {
                /* Plain text first; HTML is a fallback, not a preference. */
                if (!extract_text(mime, "plain", out->body, sizeof(out->body))) {
                    extract_text(mime, "html", out->body, sizeof(out->body));
                }
                /* Metadata only -- the bytes stay on the server until asked
                 * for, so listing what is attached costs nothing extra. */
                int ordinal = 0;
                collect_attachments(mime, out, &ordinal);
                mailmime_free(mime);
            }
        }
    }

    mailimap_fetch_list_free(result);
    return 0;
}

/* Fetches one attachment's decoded bytes into `out`.
 *
 * Returns the byte count, -2 if `cap` is too small, or -1 on any failure.
 *
 * This refetches the message rather than caching it from ronny_fetch_message.
 * That is one extra round trip, taken deliberately: caching would mean holding
 * a whole multi-megabyte message for every mail the owner merely looked at,
 * and attachments are downloaded far less often than mail is read.
 */
long ronny_fetch_attachment(mailimap *session, uint32_t uid, uint32_t index,
                            char *out, size_t cap) {
    if (session == NULL || out == NULL || cap == 0) return -1;

    struct mailimap_set *set = mailimap_set_new_single(uid);
    if (set == NULL) return -1;

    struct mailimap_section *section = mailimap_section_new(NULL);
    if (section == NULL) { mailimap_set_free(set); return -1; }

    struct mailimap_fetch_att *att = mailimap_fetch_att_new_body_peek_section(section);
    if (att == NULL) { mailimap_section_free(section); mailimap_set_free(set); return -1; }

    struct mailimap_fetch_type *fetch_type = mailimap_fetch_type_new_fetch_att(att);
    if (fetch_type == NULL) { mailimap_fetch_att_free(att); mailimap_set_free(set); return -1; }

    clist *result = NULL;
    int r = mailimap_uid_fetch(session, set, fetch_type, &result);
    mailimap_fetch_type_free(fetch_type);
    mailimap_set_free(set);
    if (r != MAILIMAP_NO_ERROR) return -1;

    long written = -1;
    for (clistiter *it = clist_begin(result); it != NULL && written < 0; it = clist_next(it)) {
        struct mailimap_msg_att *msg = clist_content(it);
        if (msg == NULL) continue;

        for (clistiter *ait = clist_begin(msg->att_list); ait != NULL; ait = clist_next(ait)) {
            struct mailimap_msg_att_item *item = clist_content(ait);
            if (item == NULL || item->att_type != MAILIMAP_MSG_ATT_ITEM_STATIC) continue;

            struct mailimap_msg_att_static *stat = item->att_data.att_static;
            if (stat == NULL || stat->att_type != MAILIMAP_MSG_ATT_BODY_SECTION) continue;

            const char *raw = stat->att_data.att_body_section->sec_body_part;
            size_t raw_len = stat->att_data.att_body_section->sec_length;
            if (raw == NULL || raw_len == 0) continue;

            size_t position = 0;
            struct mailmime *mime = NULL;
            if (mailmime_parse(raw, raw_len, &position, &mime) == MAILIMF_NO_ERROR && mime != NULL) {
                int ordinal = 0;
                written = decode_part(mime, index, &ordinal, out, cap);
                mailmime_free(mime);
            }
            break;
        }
    }

    mailimap_fetch_list_free(result);
    return written;
}

/* Reports C's view of the shared struct layouts.
 *
 * Every struct here is declared twice -- once in C, once as a Zig extern
 * struct -- and a mismatch does not fail to compile. It silently reads the
 * wrong bytes, which surfaces as garbled filenames or nonsense sizes a long
 * way from the cause. imap.zig asserts these at test time.
 *
 * `which`: 0 sizeof(ronny_envelope), 1 sizeof(ronny_message),
 *          2 sizeof(ronny_attachment), 3 offsetof(message, attachment_count),
 *          4 offsetof(message, attachments), 5 offsetof(attachment, size),
 *          6 offsetof(attachment, index), 7 offsetof(attachment, is_inline).
 */
size_t ronny_layout(int which) {
    switch (which) {
    case 0: return sizeof(ronny_envelope);
    case 1: return sizeof(ronny_message);
    case 2: return sizeof(ronny_attachment);
    case 3: return offsetof(ronny_message, attachment_count);
    case 4: return offsetof(ronny_message, attachments);
    case 5: return offsetof(ronny_attachment, size);
    case 6: return offsetof(ronny_attachment, index);
    case 7: return offsetof(ronny_attachment, is_inline);
    default: return (size_t)-1;
    }
}

/* ---- searching ---- */

/* Fills envelopes for a list of UIDs, newest first. Shared by both searches. */
static int envelopes_for_uids(mailimap *session, clist *uid_list,
                              ronny_envelope *out, int max_out) {
    if (uid_list == NULL) return 0;

    /* Newest first: a question about mail is far more often about recent mail.
     *
     * IMAP returns SEARCH results in ascending UID order, so when there are
     * more matches than fit here the ones to keep are at the END of the list.
     * Taking the first 512 instead would quietly answer a search for a common
     * word with the oldest mail in the mailbox, having discarded everything
     * recent before sorting. */
    uint32_t best[512];
    int n = 0;
    int total = 0;
    for (clistiter *it = clist_begin(uid_list); it != NULL; it = clist_next(it)) total++;
    int skip = total > 512 ? total - 512 : 0;
    int seen = 0;
    for (clistiter *it = clist_begin(uid_list); it != NULL && n < 512; it = clist_next(it)) {
        if (seen++ < skip) continue;
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

/* ---- contacts ---- */

#define RONNY_CONTACT_NAME 96
#define RONNY_CONTACT_ADDR 128

typedef struct {
    char name[RONNY_CONTACT_NAME];     /* display name, RFC 2047 decoded */
    char address[RONNY_CONTACT_ADDR];  /* mailbox@host */
    uint32_t count;                    /* messages from them in the window */
} ronny_contact;

/* Everyone who has written to this mailbox recently, most frequent first.
 *
 * This exists so composing a new email can *select* a recipient rather than
 * have a model invent one. Every address here came off a real message, so a
 * hallucinated recipient is not merely unlikely, it is unavailable.
 *
 * The frequency count is what makes "email dana" resolve sensibly when two
 * people share a first name: the one who actually corresponds wins.
 */
int ronny_contacts(mailimap *session, int days, ronny_contact *out, int max_out) {
    if (session == NULL || out == NULL || max_out <= 0) return -1;
    memset(out, 0, (size_t)max_out * sizeof(ronny_contact));

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
    for (clistiter *it = clist_begin(result); it != NULL; it = clist_next(it)) {
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
            if (addr == NULL || addr->ad_mailbox_name == NULL || addr->ad_host_name == NULL) continue;

            char address[RONNY_CONTACT_ADDR];
            snprintf(address, sizeof(address), "%s@%s", addr->ad_mailbox_name, addr->ad_host_name);

            int existing = -1;
            for (int i = 0; i < count; i++) {
                if (strcasecmp(out[i].address, address) == 0) { existing = i; break; }
            }
            if (existing >= 0) {
                out[existing].count++;
                /* Keep the first display name seen; later ones are often
                 * "Name via List" or other decorations. */
                continue;
            }
            if (count >= max_out) continue;

            copy_bounded(out[count].address, sizeof(out[count].address), address);
            if (addr->ad_personal_name != NULL) {
                decode_header(out[count].name, sizeof(out[count].name), addr->ad_personal_name);
            }
            out[count].count = 1;
            count++;
        }
    }
    mailimap_fetch_list_free(result);

    /* Most frequent first, so a first name resolves to whoever actually
     * corresponds rather than whoever happens to be alphabetically lucky. */
    for (int i = 0; i < count - 1; i++)
        for (int j = i + 1; j < count; j++)
            if (out[j].count > out[i].count) {
                ronny_contact tmp = out[i]; out[i] = out[j]; out[j] = tmp;
            }

    return count;
}

/* Everything received in the last `days`, newest first, whoever sent it.
 *
 * Separate from ronny_search_from because "what came in this morning" has no
 * sender to search on. It could be faked by searching FROM "@", since every
 * From header contains one, but that leans on a substring quirk to express
 * something IMAP says directly.
 */
int ronny_search_recent(mailimap *session, int days,
                        ronny_envelope *out, int max_out) {
    if (session == NULL || out == NULL || max_out <= 0) return -1;

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

    return envelopes_for_uids(session, uid_list, out, max_out);
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
