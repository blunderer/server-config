#!/usr/bin/env python3
"""smtp_login.py ADDRESS NAME USER PASSWORD_FILE: what a mail client does.

Connects to ADDRESS on port 587, STARTTLS with a certificate that must be
valid for NAME (as a client asking for NAME sees it), then logs in as USER.
Exit 0 when all of that works; otherwise exit 1 and print the step that
failed. Used by `box smtp-health` (smtp.blunderer.org).
"""
import smtplib
import ssl
import sys


def main():
    if len(sys.argv) != 5:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    address, name, user, pwfile = sys.argv[1:]
    with open(pwfile, encoding="utf-8") as f:
        password = f.readline().rstrip("\n")
    step = "connect"
    try:
        smtp = smtplib.SMTP(timeout=15)
        smtp.connect(address, 587)
        # Check the certificate against NAME, not the address we connected to.
        smtp._host = name
        step = "EHLO"
        smtp.ehlo()
        step = "STARTTLS"
        smtp.starttls(context=ssl.create_default_context())
        smtp.ehlo()
        step = "AUTH"
        smtp.login(user, password)
        smtp.quit()
    except (OSError, smtplib.SMTPException, ssl.SSLError) as e:
        print(f"{step}: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
