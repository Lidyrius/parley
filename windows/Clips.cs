using System.Text;

namespace Parley;

// Cached spoken clips — ack lines per intent and per-project announcements — rendered
// lazily via Google TTS into %APPDATA%\Parley\clips and picked at random for variety.
// Same phrase templates as the macOS scripts/clip-texts (all six languages).
public static class Clips
{
    private static string Root => Path.Combine(Config.Dir, "clips");
    private static readonly HashSet<string> Rendering = new();
    private static readonly object Gate = new();

    // ---- ack lines -------------------------------------------------------------------

    /// Random cached ack clip PCM for the intent, or null (kicks off a background render).
    public static byte[]? AckClip(Groq.Intent intent, Config config)
    {
        var lang = LangFile(config.Language);
        var dir = Path.Combine(Root, "lines", lang, IntentKey(intent));
        var pick = RandomPcm(dir);
        if (pick is not null) return pick;
        EnsureRendered("lines-" + lang, config, () => RenderAckLines(lang, config));
        return null;
    }

    // ---- project announcements -------------------------------------------------------

    public static byte[]? Announcement(string label, Config config)
    {
        var slug = Slug(label);
        if (slug.Length == 0) return null;
        var dir = Path.Combine(Root, "projects", slug);
        var pick = RandomPcm(dir);
        if (pick is not null) return pick;
        EnsureRendered("proj-" + slug, config, () => RenderAnnouncements(label, slug, config));
        return null;
    }

    // ---- rendering -------------------------------------------------------------------

    private static void EnsureRendered(string key, Config config, Func<Task> render)
    {
        if (!config.UseGoogle) return;
        lock (Gate)
        {
            if (!Rendering.Add(key)) return;
        }
        _ = Task.Run(async () =>
        {
            try { await render(); }
            finally { lock (Gate) Rendering.Remove(key); }
        });
    }

    private static async Task RenderAckLines(string lang, Config config)
    {
        Log.Write($"clips: rendering ack lines ({lang})");
        foreach (var (key, text) in ParseTemplate(Template(lang)))
        {
            if (key == "ready") continue;   // greeting clips are no longer played
            var dir = Path.Combine(Root, "lines", lang, key);
            Directory.CreateDirectory(dir);
            var n = Directory.GetFiles(dir, "*.pcm").Length;
            var pcm = await GoogleTts.Synthesize(text, config);
            if (pcm is not null)
                await File.WriteAllBytesAsync(Path.Combine(dir, $"line_{n:00}.pcm"), pcm);
        }
        Log.Write("clips: ack lines done");
    }

    private static async Task RenderAnnouncements(string label, string slug, Config config)
    {
        Log.Write($"clips: rendering announcements for {label}");
        var dir = Path.Combine(Root, "projects", slug);
        Directory.CreateDirectory(dir);
        var i = 0;
        foreach (var phrase in AnnouncementPhrases(config.Language))
        {
            var pcm = await GoogleTts.Synthesize(phrase.Replace("{name}", label), config);
            if (pcm is not null)
                await File.WriteAllBytesAsync(Path.Combine(dir, $"ann_{i:00}.pcm"), pcm);
            i++;
        }
        Log.Write("clips: announcements done");
    }

    // ---- helpers ---------------------------------------------------------------------

    private static byte[]? RandomPcm(string dir)
    {
        try
        {
            var files = Directory.Exists(dir) ? Directory.GetFiles(dir, "*.pcm") : Array.Empty<string>();
            if (files.Length == 0) return null;
            return File.ReadAllBytes(files[Random.Shared.Next(files.Length)]);
        }
        catch { return null; }
    }

    private static string IntentKey(Groq.Intent i) => i switch
    {
        Groq.Intent.Feature => "feature",
        Groq.Intent.Bug => "bug",
        Groq.Intent.Research => "research",
        Groq.Intent.Question => "question",
        Groq.Intent.Stop => "stop",
        Groq.Intent.Continue => "continue",
        Groq.Intent.FeatureResearch => "feature_research",
        Groq.Intent.BugFeature => "bug_feature",
        _ => "other",
    };

    private static string Slug(string s)
    {
        var sb = new StringBuilder();
        foreach (var c in s.ToLowerInvariant())
            sb.Append(char.IsLetterOrDigit(c) ? c : '-');
        return sb.ToString().Trim('-');
    }

    private static IEnumerable<(string key, string text)> ParseTemplate(string tpl)
    {
        foreach (var line in tpl.Split('\n'))
        {
            var t = line.Trim();
            var idx = t.IndexOf('|');
            if (idx > 0) yield return (t[..idx], t[(idx + 1)..]);
        }
    }

    private static string LangFile(string language) => language switch
    {
        "English" => "en-US", "Français" => "fr-FR", "Español" => "es-ES",
        "Italiano" => "it-IT", "Nederlands" => "nl-NL", _ => "de-DE",
    };

    private static string Template(string langFile) => langFile switch
    {
        "en-US" => EnUS, "fr-FR" => FrFR, "es-ES" => EsES, "it-IT" => ItIT, "nl-NL" => NlNL, _ => DeDE,
    };

    private static string[] AnnouncementPhrases(string language) => language switch
    {
        "English" => new[] { "I have an update on the {name} project.", "News from the {name} project.", "A quick note on {name}.", "Update for {name}.", "Regarding the {name} project.", "Something new on {name}.", "Feedback on {name}.", "This concerns the {name} project.", "This is {name}.", "On the status of {name}." },
        "Français" => new[] { "J'ai une mise à jour pour le projet {name}.", "Des nouvelles du projet {name}.", "Un mot rapide sur {name}.", "Mise à jour pour {name}.", "Concernant le projet {name}.", "Du nouveau sur {name}.", "Un retour sur {name}.", "Cela concerne le projet {name}.", "Ici {name}.", "Sur l'état de {name}." },
        "Español" => new[] { "Tengo una actualización del proyecto {name}.", "Novedades del proyecto {name}.", "Una nota rápida sobre {name}.", "Actualización de {name}.", "Sobre el proyecto {name}.", "Algo nuevo en {name}.", "Comentarios sobre {name}.", "Esto concierne al proyecto {name}.", "Aquí {name}.", "Sobre el estado de {name}." },
        "Italiano" => new[] { "Ho un aggiornamento per il progetto {name}.", "Novità dal progetto {name}.", "Una breve nota su {name}.", "Aggiornamento per {name}.", "Riguardo al progetto {name}.", "Qualcosa di nuovo su {name}.", "Un riscontro su {name}.", "Riguarda il progetto {name}.", "Qui {name}.", "Sullo stato di {name}." },
        "Nederlands" => new[] { "Ik heb een update voor het project {name}.", "Nieuws uit het project {name}.", "Een korte melding over {name}.", "Update voor {name}.", "Over het project {name}.", "Iets nieuws over {name}.", "Een terugkoppeling over {name}.", "Dit betreft het project {name}.", "Hier is {name}.", "Over de status van {name}." },
        _ => new[] { "Ich habe ein Update für das Projekt {name}.", "Neuigkeiten aus dem Projekt {name}.", "Kurze Meldung zum Projekt {name}.", "Update für {name}.", "Zum Projekt {name}.", "Neues aus dem Projekt {name}.", "Eine Rückmeldung zu {name}.", "Betrifft das Projekt {name}.", "Hier ist {name}.", "Zum Stand von {name}." },
    };

    // ---- phrase templates (key|text; identical to scripts/clip-texts/*.txt) ----------

    private const string DeDE = """
feature|Sehr wohl, Sir. Ich baue es ein und melde mich, sobald es fertig ist.
feature|Verstanden. Ich setze das um und gebe Bescheid, wenn es steht.
feature|Alles klar, ich mache mich an den Einbau und melde mich mit dem Ergebnis.
bug|Verstanden, Sir. Ich untersuche das sofort und melde mich mit einer Lösung.
bug|Alles klar, ich gehe dem Fehler auf den Grund und behebe ihn.
bug|Zu Diensten. Ich sehe mir das Problem an und melde mich, wenn es behoben ist.
stop|Sehr wohl, Sir. Ich halte hier an.
stop|Verstanden, ich stoppe und warte auf Ihre nächste Anweisung.
stop|Alles klar, ich pausiere.
continue|Gut, Sir. Ich fahre fort.
continue|Verstanden, ich mache weiter.
continue|Sehr wohl, ich setze fort, Sir.
other|Verstanden, Sir. Ich kümmere mich darum.
other|Alles klar, ich sehe mir das an.
other|Zu Diensten. Ich nehme mich der Sache an.
question|Gute Frage, Sir. Ich prüfe das kurz und habe gleich eine Antwort.
question|Einen Augenblick, ich sehe nach und antworte sogleich.
question|Lassen Sie mich das kurz prüfen, dann habe ich Ihre Antwort.
research|Verstanden, Sir. Ich recherchiere das kurz und melde mich.
research|Alles klar, ich sehe mich kurz um und berichte Ihnen.
research|Zu Diensten. Ich schaue mich um und komme mit Ergebnissen zurück.
feature_research|Sehr wohl, ich recherchiere kurz und baue das Feature dann ein.
feature_research|Verstanden — erst die Recherche, dann der Einbau. Ich melde mich.
bug_feature|Verstanden, Sir. Ich behebe den Fehler und baue die Erweiterung ein.
bug_feature|Alles klar, Fix und Feature — ich mache mich an beides.
""";

    private const string EnUS = """
feature|Very good, Sir. I'll build it in and report back once it's done.
feature|Understood. I'll implement that and let you know when it's ready.
feature|Right away — I'll get to work on it and report with the result.
bug|Understood, Sir. I'll look into it at once and report back with a fix.
bug|Right, I'll get to the bottom of the fault and resolve it.
bug|At your service. I'll examine the problem and report when it's fixed.
stop|Very good, Sir. I'll stop here.
stop|Understood, I'll halt and await your next instruction.
stop|Right, I'll pause.
continue|Very good, Sir. I'll carry on.
continue|Understood, I'll continue.
continue|Very good, I'll proceed, Sir.
other|Understood, Sir. I'll see to it.
other|Right, I'll take a look.
other|At your service. I'll attend to it.
question|Good question, Sir. Let me check and I'll have an answer shortly.
question|One moment, I'll look into it and answer directly.
question|Let me verify that briefly, then I'll have your answer.
research|Understood, Sir. I'll research that and report back.
research|Right, I'll have a look around and report to you.
research|At your service. I'll look into it and return with findings.
feature_research|Very good, I'll research briefly and then build the feature.
feature_research|Understood — research first, then the build. I'll report back.
bug_feature|Understood, Sir. I'll fix the fault and build the addition.
bug_feature|Right, fix and feature — I'll get to both.
""";

    private const string FrFR = """
feature|Très bien, Monsieur. Je l'intègre et je vous préviens dès que c'est fait.
feature|Entendu. Je m'en occupe et vous informe dès que c'est prêt.
feature|Tout de suite — je me mets à l'ouvrage et je reviens avec le résultat.
bug|Entendu, Monsieur. J'examine cela sur-le-champ et reviens avec une solution.
bug|Bien, je vais au fond du problème et je le corrige.
bug|À votre service. J'examine le problème et vous préviens une fois résolu.
stop|Très bien, Monsieur. Je m'arrête ici.
stop|Entendu, je m'arrête et j'attends votre prochaine instruction.
stop|Bien, je fais une pause.
continue|Bien, Monsieur. Je poursuis.
continue|Entendu, je continue.
continue|Très bien, je poursuis, Monsieur.
other|Entendu, Monsieur. Je m'en occupe.
other|Bien, je vais jeter un œil.
other|À votre service. Je prends la chose en main.
question|Bonne question, Monsieur. Je vérifie et j'ai une réponse dans l'instant.
question|Un instant, je regarde et je réponds aussitôt.
question|Laissez-moi vérifier brièvement, puis j'aurai votre réponse.
research|Entendu, Monsieur. Je fais une petite recherche et reviens vers vous.
research|Bien, je regarde autour et je vous fais un rapport.
research|À votre service. Je me renseigne et reviens avec des résultats.
feature_research|Très bien, je fais une brève recherche puis j'intègre la fonctionnalité.
feature_research|Entendu — d'abord la recherche, ensuite l'intégration. Je vous préviens.
bug_feature|Entendu, Monsieur. Je corrige le défaut et j'ajoute l'extension.
bug_feature|Bien, correction et fonctionnalité — je m'occupe des deux.
""";

    private const string EsES = """
feature|Muy bien, señor. Lo incorporo y le aviso en cuanto esté listo.
feature|Entendido. Me encargo de ello y le informo cuando esté hecho.
feature|Enseguida — me pongo con ello y vuelvo con el resultado.
bug|Entendido, señor. Lo examino de inmediato y vuelvo con una solución.
bug|Bien, iré al fondo del fallo y lo corregiré.
bug|A su servicio. Reviso el problema y le aviso cuando esté resuelto.
stop|Muy bien, señor. Me detengo aquí.
stop|Entendido, me detengo y aguardo su próxima indicación.
stop|Bien, hago una pausa.
continue|Bien, señor. Continúo.
continue|Entendido, sigo adelante.
continue|Muy bien, prosigo, señor.
other|Entendido, señor. Me ocupo de ello.
other|Bien, echaré un vistazo.
other|A su servicio. Me hago cargo del asunto.
question|Buena pregunta, señor. Lo compruebo y tendré una respuesta enseguida.
question|Un momento, lo reviso y respondo de inmediato.
question|Permítame verificarlo brevemente y tendré su respuesta.
research|Entendido, señor. Investigo el asunto y vuelvo a informarle.
research|Bien, echo un vistazo y le doy un informe.
research|A su servicio. Me informo y vuelvo con resultados.
feature_research|Muy bien, investigo brevemente y luego incorporo la función.
feature_research|Entendido — primero la investigación, luego la incorporación. Le aviso.
bug_feature|Entendido, señor. Corrijo el fallo e incorporo la ampliación.
bug_feature|Bien, corrección y función — me ocupo de ambas.
""";

    private const string ItIT = """
feature|Molto bene, signore. Lo integro e la avviso non appena è pronto.
feature|Inteso. Me ne occupo e le faccio sapere quando è fatto.
feature|Subito — mi metto all'opera e torno con il risultato.
bug|Inteso, signore. Esamino la cosa immediatamente e torno con una soluzione.
bug|Bene, vado a fondo del problema e lo risolvo.
bug|Al suo servizio. Esamino il problema e la avviso una volta risolto.
stop|Molto bene, signore. Mi fermo qui.
stop|Inteso, mi fermo e attendo la sua prossima istruzione.
stop|Bene, faccio una pausa.
continue|Bene, signore. Proseguo.
continue|Inteso, continuo.
continue|Molto bene, proseguo, signore.
other|Inteso, signore. Me ne occupo.
other|Bene, do un'occhiata.
other|Al suo servizio. Prendo in mano la questione.
question|Bella domanda, signore. Controllo e avrò una risposta a breve.
question|Un momento, do un'occhiata e rispondo subito.
question|Mi lasci verificare brevemente, poi avrò la sua risposta.
research|Inteso, signore. Faccio una breve ricerca e torno da lei.
research|Bene, do un'occhiata in giro e le riferisco.
research|Al suo servizio. Mi informo e torno con dei risultati.
feature_research|Molto bene, faccio una breve ricerca e poi integro la funzione.
feature_research|Inteso — prima la ricerca, poi l'integrazione. La avviso.
bug_feature|Inteso, signore. Correggo il difetto e aggiungo l'estensione.
bug_feature|Bene, correzione e funzione — mi occupo di entrambe.
""";

    private const string NlNL = """
feature|Zeer goed, meneer. Ik bouw het in en meld me zodra het klaar is.
feature|Begrepen. Ik voer het uit en laat het weten wanneer het gereed is.
feature|Meteen — ik ga ermee aan de slag en kom terug met het resultaat.
bug|Begrepen, meneer. Ik onderzoek het onmiddellijk en kom terug met een oplossing.
bug|Goed, ik zoek de fout tot op de bodem uit en verhelp hem.
bug|Tot uw dienst. Ik bekijk het probleem en meld me zodra het verholpen is.
stop|Zeer goed, meneer. Ik stop hier.
stop|Begrepen, ik stop en wacht op uw volgende aanwijzing.
stop|Goed, ik pauzeer.
continue|Goed, meneer. Ik ga verder.
continue|Begrepen, ik ga door.
continue|Zeer goed, ik zet het voort, meneer.
other|Begrepen, meneer. Ik zorg ervoor.
other|Goed, ik werp er een blik op.
other|Tot uw dienst. Ik neem de zaak op me.
question|Goede vraag, meneer. Ik controleer het even en heb zo een antwoord.
question|Een ogenblik, ik kijk het na en antwoord meteen.
question|Laat me het even verifiëren, dan heb ik uw antwoord.
research|Begrepen, meneer. Ik zoek het even uit en meld me.
research|Goed, ik kijk even rond en breng u verslag uit.
research|Tot uw dienst. Ik informeer en kom terug met resultaten.
feature_research|Zeer goed, ik doe kort onderzoek en bouw daarna de functie in.
feature_research|Begrepen — eerst het onderzoek, dan de inbouw. Ik meld me.
bug_feature|Begrepen, meneer. Ik verhelp de fout en bouw de uitbreiding in.
bug_feature|Goed, fix en functie — ik pak beide aan.
""";
}
