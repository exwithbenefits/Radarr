using System.Collections.Generic;
using NzbDrone.Core.Datastore;
using NzbDrone.Core.Languages;
using NzbDrone.Core.Messaging.Events;

namespace NzbDrone.Core.Movies.Translations
{
    public interface IMovieTranslationRepository : IBasicRepository<MovieTranslation>
    {
        List<MovieTranslation> FindByMovieMetadataId(int movieMetadataId);
        List<MovieTranslation> FindByMovieMetadataIds(List<int> movieMetadataIds, Language language);
        List<MovieTranslation> FindByLanguage(Language language);
        void DeleteForMovies(List<int> movieIds);
    }

    public class MovieTranslationRepository : BasicRepository<MovieTranslation>, IMovieTranslationRepository
    {
        public MovieTranslationRepository(IMainDatabase database, IEventAggregator eventAggregator)
            : base(database, eventAggregator)
        {
        }

        public List<MovieTranslation> FindByMovieMetadataId(int movieMetadataId)
        {
            return Query(x => x.MovieMetadataId == movieMetadataId);
        }

        public List<MovieTranslation> FindByMovieMetadataIds(List<int> movieMetadataIds, Language language)
        {
            return Query(x => movieMetadataIds.Contains(x.MovieMetadataId) && x.Language == language);
        }

        public List<MovieTranslation> FindByLanguage(Language language)
        {
            return Query(x => x.Language == language);
        }

        public void DeleteForMovies(List<int> movieIds)
        {
            Delete(x => movieIds.Contains(x.MovieMetadataId));
        }
    }
}
