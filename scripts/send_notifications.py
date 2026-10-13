
import json
import os
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import firebase_admin
from firebase_admin import credentials, messaging

SITE = "https://www.amiidonk.hu"
API = SITE + "/wp-json/wp/v2/posts?per_page=20&_fields=id,date_gmt,link,title,status"
STATE_FILE = Path("scripts/last_post.json")
TOPIC = "uj_cikkek"


def fetch_posts():
    request = urllib.request.Request(
        API,
        headers={"User-Agent": "A-MI-IDONK-Notification-Bot/1.0"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main():
    service_account = json.loads(os.environ["FIREBASE_SERVICE_ACCOUNT"])
    firebase_admin.initialize_app(
        credentials.Certificate(service_account)
    )

    posts = fetch_posts()
    if not posts:
        print("Nincsenek cikkek.")
        return

    posts.sort(key=lambda post: post["id"])

    if STATE_FILE.exists():
        state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        last_id = int(state["last_id"])
    else:
        # Első futtatáskor nem küldünk értesítést a régi cikkekről.
        last_id = max(post["id"] for post in posts)
        save_state(last_id)
        print("Első indítás: meglévő cikkek rögzítve.")
        return

    new_posts = [post for post in posts if post["id"] > last_id]

    for post in new_posts:
        title = post["title"]["rendered"]
        link = post["link"]

        message = messaging.Message(
            notification=messaging.Notification(
                title="A MI IDŐNK – Új cikk",
                body=title,
            ),
            data={
                "article_url": link,
                "post_id": str(post["id"]),
            },
            topic=TOPIC,
        )

        message_id = messaging.send(message)
        print(f"Elküldve: {post['id']} – {message_id}")
        save_state(post["id"])

    if not new_posts:
        print("Nincs új cikk.")


def save_state(last_id):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(
        json.dumps({
            "last_id": last_id,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }, indent=2),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
