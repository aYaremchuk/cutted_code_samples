(function() {
    var showing;
    showing = JSON.parse(localStorage.showing || "null");
    if (!showing) {
        showing = {box: true};
    }
    else {
        showBox(showing.box);
    }

    document.getElementById("box-switcher").onclick = cbclicked;
    function cbclicked() {
        var box = "box";
        showing[box] = !showing[box];
        showBox(showing[box]);
        localStorage.showing = JSON.stringify(showing);
    }

    function showBox(flag ) {
        document.getElementById("box-switcher").checked = flag;
        document.getElementById("box").style.display = flag ? "none" : "block";
        document.getElementById("box-switcher").innerHTML = flag ?  'Show pages with ads &#9660;': 'Pages with ads &#9650;';
    }
})();