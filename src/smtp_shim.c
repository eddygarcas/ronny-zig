/* SMTP sending, the only path in Ronny that can send an email.
 *
 * Deliberately dumb: it takes an explicit recipient and a fully-formed
 * message and sends it. It makes no decisions. Every safety rule lives at
 * the call site -- the recipient comes from a fetched message's headers and
 * never from model output, and nothing reaches here without the owner
 * approving the draft.
 *
 * In C for the same reason as the rest of the libetpan boundary: the address
 * list is a clist of tagged structures.
 */

#include <libetpan/libetpan.h>
#include <stdlib.h>
#include <string.h>

/* Returns 0 on success, or the libetpan error code. */
int ronny_smtp_send(const char *host, uint16_t port,
                    const char *user, const char *password,
                    const char *from, const char *to,
                    const char *message, size_t message_len) {
    if (host == NULL || user == NULL || password == NULL ||
        from == NULL || to == NULL || message == NULL) return -1;

    int result = -1;
    mailsmtp *smtp = mailsmtp_new(0, NULL);
    if (smtp == NULL) return -1;

    clist *recipients = NULL;

    if (mailsmtp_socket_connect(smtp, host, port) != MAILSMTP_NO_ERROR) goto done;
    if (mailsmtp_init(smtp) != MAILSMTP_NO_ERROR) goto done;

    /* Gmail requires STARTTLS on 587 before it will accept credentials.
     * EHLO must be repeated afterwards: the server advertises a different
     * capability set once the connection is encrypted. */
    if (mailsmtp_socket_starttls(smtp) != MAILSMTP_NO_ERROR) goto done;
    if (mailsmtp_init(smtp) != MAILSMTP_NO_ERROR) goto done;

    if (mailsmtp_auth(smtp, user, password) != MAILSMTP_NO_ERROR) goto done;

    recipients = clist_new();
    if (recipients == NULL) goto done;
    if (clist_append(recipients, (void *)to) != 0) goto done;

    result = mailesmtp_send(smtp, from, 0, NULL, recipients, message, message_len);

done:
    if (recipients != NULL) clist_free(recipients);
    mailsmtp_free(smtp);
    return result;
}
