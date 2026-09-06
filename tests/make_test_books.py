#!/usr/bin/env python3
"""Generate minimal multilingual test EPUBs for KOReader emulator testing.

Each book carries an explicit dc:language so the plugin's context-aware
language detection (and v1.3.0 dynamic button slots) can be exercised
without relying on real-world books' metadata quality.
"""
import os
import sys
import zipfile

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "library")
os.makedirs(OUT_DIR, exist_ok=True)

BOOKS = {
    "量子力学史话-中文测试.epub": ("zh", [
        ("h", "第一章 量子力学的诞生"),
        ("p", "十九世纪末，物理学的大厦已经落成。量子力学的概念在当时显得匪夷所思。普朗克提出了量子假说。"),
        ("p", "微观世界的量子纠缠与波粒二象性逐渐被接受。薛定谔的猫是著名的思想实验。"),
    ]),
    "Traditional-TraditionalBook.epub": ("zh-Hant", [
        ("h", "第一章 量子力學的誕生"),
        ("p", "十九世紀末，物理學的大廈已經落成。量子力學的概念在當時顯得匪夷所思。普朗克提出了量子假說。"),
        ("p", "微觀世界的量子糾纏與波粒二象性逐漸被接受。薛定諤的貓是著名的思想實驗。"),
    ]),
    "German-Physics-Test.epub": ("de", [
        ("h", "Kapitel 1: Die Quantenmechanik"),
        ("p", "Die Quantenmechanik ist ein zentrales Gebiet der Physik. Physiker wie Heisenberg und Schroedinger entwickelten die Theorie weiter."),
        ("p", "Das Heisenbergsche Unschaerfeprinzip beschraenkt die gleichzeitige Messbarkeit von Ort und Impuls."),
    ]),
    "Russian-Science-Test.epub": ("ru", [
        ("h", "Глава 1: Квантовая механика"),
        ("p", "Квантовая механика изучает поведение микрочастиц. Учёные Ландау и Капица внесли вклад в физику."),
        ("p", "Принцип неопределённости Гейзенберга ограничивает точность измерений."),
    ]),
    "French-Philosophy-Test.epub": ("fr", [
        ("h", "Chapitre 1 : La philosophie moderne"),
        ("p", "La philosophie des Lumieres a transforme la pensee europeenne. Descartes et Voltaire en sont les figures majeures."),
        ("p", "Le doute cartésien fonde la connaissance sur la raison."),
        # v1.3.2 elision selection material: l'équation → Équation,
        # l'évolution → Évolution, l'histoire → Histoire on fr.wikipedia
        ("p", "L'équation de Schrödinger décrit l'évolution des systèmes quantiques."),
        ("p", "C'est l'histoire d'une idée qui a changé le monde."),
    ]),
    "Spanish-History-Test.epub": ("es", [
        ("h", "Capítulo 1: La historia antigua"),
        ("p", "La historia de Roma es apasionante. El imperio romano dominó el Mediterráneo durante siglos."),
        ("p", "Julio César cambió el curso de la república."),
    ]),
    "Japanese-Literature-Test.epub": ("ja", [
        ("h", "第一章 涼宮ハルヒの憂鬱"),
        ("p", "涼宮ハルヒの憂鬱はライトノベルの代表作である。シャナの戦いも有名だ。"),
        ("p", "日本語の物語には独特の助詞が使われる。"),
    ]),
    "English-Science-Test.epub": ("en", [
        ("h", "Chapter 1: Quantum mechanics"),
        ("p", "Quantum mechanics is a fundamental theory in physics. Wookieepedia is a Star Wars wiki, and Fandom hosts many communities."),
        ("p", "Heisenberg's uncertainty principle limits simultaneous measurement of position and momentum."),
    ]),
}

XHTML = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head>\n'
    "<body>{body}</body></html>"
)
CONTAINER = (
    '<?xml version="1.0"?>\n'
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    '<rootfiles><rootfile full-path="OEBPS/content.opf"'
    ' media-type="application/oebps-package+xml"/></rootfiles>\n</container>'
)

for fname, (lang, pages) in BOOKS.items():
    path = os.path.join(OUT_DIR, fname)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zp:
        zp.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        zp.writestr("META-INF/container.xml", CONTAINER)
        manifest, spine = [], []
        for i, (kind, text) in enumerate(pages):
            pid = "page%02d" % i
            body = "<h1>%s</h1><p>%s</p>" % (text, text) if kind == "h" else "<p>%s</p>" % text
            zp.writestr("OEBPS/%s.xhtml" % pid, XHTML.format(title=fname, body=body))
            manifest.append('<item id="%s" href="%s.xhtml" media-type="application/xhtml+xml"/>' % (pid, pid))
            spine.append('<itemref idref="%s"/>' % pid)
        opf = (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="2.0">\n'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
            '<dc:identifier id="uid">test-%s-001</dc:identifier>\n'
            "<dc:title>%s</dc:title>\n"
            "<dc:language>%s</dc:language>\n"
            "</metadata>\n"
            "<manifest>%s</manifest>\n"
            "<spine>%s</spine>\n"
            "</package>"
        ) % (lang, fname, lang, "".join(manifest), "".join(spine))
        zp.writestr("OEBPS/content.opf", opf)
    print("built", path)
print("DONE")
