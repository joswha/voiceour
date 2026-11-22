"use strict";
(() => {
    const cases = Array.from(document.querySelectorAll("section"));
    const study = document.body.dataset.study;
    const storageKey = "voiceour-review:" + study;
    const notice = document.getElementById("storage");
    const progress = document.getElementById("progress");
    const radios = Array.from(document.querySelectorAll("input[type=radio]"));
    let index = 0;
    function ratings() {
        return cases.map(c => Array.from(c.querySelectorAll("article"), a => {
            const result = {};
            for (const axis of a.querySelectorAll("fieldset")) {
                const selected = axis.querySelector(":checked");
                if (selected) result[axis.dataset.axis] = selected.value;
            }
            return result;
        }));
    }
    function update() {
        cases.forEach((c, n) => { c.hidden = index !== n; });
        const complete = ratings().filter(row => row.every(r => r.meaning && r.cleanup)).length;
        progress.textContent = ` Dictation ${index + 1} of ${cases.length}. ${complete} fully rated.`;
        document.getElementById("prev").disabled = index === 0;
        document.getElementById("next").disabled = index === cases.length - 1;
    }
    function save() {
        try {
            const selected = Object.fromEntries(radios.filter(r => r.checked).map(r => [r.name, r.value]));
            localStorage.setItem(storageKey, JSON.stringify({index, selected}));
        } catch {
            notice.textContent = "Browser storage is unavailable. Finish and export before closing this page.";
        }
    }
    try {
        const prior = JSON.parse(localStorage.getItem(storageKey));
        if (prior && Number.isInteger(prior.index) && prior.index >= 0 && prior.index < cases.length && prior.selected) {
            index = prior.index;
            for (const r of radios) r.checked = prior.selected[r.name] === r.value;
        }
    } catch {
        notice.textContent = "Browser storage is unavailable. Finish and export before closing this page.";
    }
    for (const r of radios) r.addEventListener("change", () => { save(); update(); });
    function go(to) {
        index = Math.max(0, Math.min(cases.length - 1, to));
        save(); update(); window.scrollTo(0, 0);
    }
    document.getElementById("prev").addEventListener("click", () => go(index - 1));
    document.getElementById("next").addEventListener("click", () => go(index + 1));
    document.getElementById("save").addEventListener("click", () => {
        const blob = new Blob([JSON.stringify({version: 1, study, ratings: ratings()})], {type: "application/json"});
        const link = document.createElement("a");
        link.href = URL.createObjectURL(blob); link.download = `ratings-${study}.json`;
        document.body.append(link); link.click(); link.remove();
        setTimeout(() => URL.revokeObjectURL(link.href), 1000);
    });
    update();
})();
